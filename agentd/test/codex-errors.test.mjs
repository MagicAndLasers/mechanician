import assert from 'node:assert/strict'
import { EventEmitter } from 'node:events'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { PassThrough } from 'node:stream'
import { spawn } from 'node:child_process'
import { randomUUID } from 'node:crypto'
import { fileURLToPath } from 'node:url'
import { test } from 'node:test'

import { CODEX_RESPONSE_WRITTEN, CodexAppServer } from '../src/codex-app-server.mjs'
import {
  MECHANICIAN_CODEX_GUIDANCE,
  MECHANICIAN_CODEX_GUIDANCE_WITHOUT_WORKFLOW_ADVICE,
} from '../src/codex-tools.mjs'

/// Codex now receives Mechanician's tool protocol ahead of the workspace's own instructions
/// (FR-213). The property these tests exist to protect is unchanged and is asserted directly: the
/// user's text is carried VERBATIM and is never rewritten, summarized, or reordered. Comparing
/// against a composed string would just restate the implementation, so assert the two halves.
function assertDeveloperInstructions(
  actual,
  workspaceText,
  { workflowAdviceEnabled = true } = {},
) {
  const guidance = workflowAdviceEnabled
    ? MECHANICIAN_CODEX_GUIDANCE
    : MECHANICIAN_CODEX_GUIDANCE_WITHOUT_WORKFLOW_ADVICE
  assert.equal(typeof actual, 'string')
  assert.equal(actual.startsWith(guidance), true,
    'Mechanician tool guidance must lead the developer instructions')
  assert.equal(actual.endsWith(workspaceText), true,
    'workspace instructions must be carried verbatim and last')
  assert.equal(actual, `${guidance}\n\n${workspaceText}`)
  assert.equal(actual.includes('RecommendMechanicianWorkflow'), workflowAdviceEnabled)
  assert.equal(actual.includes('ShowMechanician'), workflowAdviceEnabled)
}

/// A Codex thread's config is now exactly what the profile built, with nothing layered on.
///
/// This used to assert the opposite: one `mechmem_*` loopback MCP server carrying RecallMemory and
/// RememberThis into every ordinary thread. That bridge is gone, so the claim worth pinning is
/// that no transient server is added behind the proof params — the shape a future one would take.
function assertNoTransientMcpConfig(config, expectedRest = {}) {
  const normalized = config == null ? {} : config
  assert.equal(typeof normalized, 'object')
  for (const name of Object.keys(normalized.mcp_servers || {})) {
    assert.doesNotMatch(name, /^mechmem_/, 'no loopback MCP server may be layered onto a thread')
  }
  const rest = structuredClone(normalized)
  if (rest.mcp_servers && !Object.keys(rest.mcp_servers).length) delete rest.mcp_servers
  assert.deepEqual(rest, expectedRest)
}

const here = path.dirname(fileURLToPath(import.meta.url))
const agentd = path.resolve(here, '../src/agentd.mjs')
const delay = (milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds))
const mcpAccountInstanceId = 'a1faed81-8eba-4242-97fa-b3a5d9212585'
const replacementMcpAccountInstanceId = 'E65B4B19-4CF3-4F45-B65D-4536BF6BF023'
const codexMcpRouteIdentity = 'codex:subscription:builtin'
const configuredMcpServerId = '7f661a72-4885-42ad-bce1-242b6741d88a'
const secondConfiguredMcpServerId = '6205805a-35a4-41ce-a5f0-81c644dd4d81'

function writeConfiguredMcpSidecar(support, servers = [{
  id: configuredMcpServerId,
  name: 'fixture-server', enabled: true, transport: 'stdio', command: '/bin/echo',
}]) {
  fs.mkdirSync(support, { recursive: true })
  fs.writeFileSync(path.join(support, 'extensions.json'), JSON.stringify({ mcpServers: servers }))
}

function writeConfiguredCodexReadiness(support, changeId) {
  writeCodexReadiness(support, [{
    name: 'fixture-server', changeId, source: 'configured',
    serverID: configuredMcpServerId, accountInstanceID: mcpAccountInstanceId,
    routeIdentity: codexMcpRouteIdentity,
  }])
}

function writeCodexReadiness(support, claims, servers = [{
  id: configuredMcpServerId,
  name: 'fixture-server', enabled: true, transport: 'stdio', command: '/bin/echo',
}]) {
  fs.mkdirSync(support, { recursive: true })
  fs.writeFileSync(path.join(support, 'extensions.json'), JSON.stringify({
    mcpServers: servers,
    pendingMCPReadiness: { byAccess: { codex_subscription: claims } },
  }))
}

function writePendingCodexMcpSidecar(support, { authorization = false } = {}) {
  const claim = {
    name: 'fixture-server', source: 'configured', serverID: configuredMcpServerId,
    accountInstanceID: mcpAccountInstanceId, routeIdentity: codexMcpRouteIdentity,
  }
  fs.mkdirSync(support, { recursive: true })
  fs.writeFileSync(path.join(support, 'extensions.json'), JSON.stringify({
    mcpServers: [{
      id: configuredMcpServerId,
      name: 'fixture-server', enabled: true, transport: 'stdio', command: '/bin/echo',
    }],
    pendingMCPReadiness: { byAccess: {
      codex_subscription: authorization ? [] : [{ ...claim, changeId: 'pending-generation' }],
    } },
    pendingMCPAuthorizations: { byAccess: {
      codex_subscription: authorization ? [{
        ...claim, id: 'pending-attempt', operation: 'authorize',
        createdAt: '2026-08-13T12:00:00Z',
      }] : [],
    } },
  }))
}

function writePendingCodexAuthorization(support, attemptId) {
  fs.mkdirSync(support, { recursive: true })
  fs.writeFileSync(path.join(support, 'extensions.json'), JSON.stringify({
    mcpServers: [{
      id: configuredMcpServerId,
      name: 'fixture-server', enabled: true, transport: 'stdio', command: '/bin/echo',
    }],
    pendingMCPReadiness: { byAccess: { codex_subscription: [] } },
    pendingMCPAuthorizations: { byAccess: { codex_subscription: [{
      id: attemptId, name: 'fixture-server', source: 'configured',
      operation: 'authorize', serverID: configuredMcpServerId,
      accountInstanceID: mcpAccountInstanceId, routeIdentity: codexMcpRouteIdentity,
      createdAt: '2026-08-13T12:00:00Z',
    }] } },
  }))
}

function writePendingCodexAuthorizationAndReadiness(support, attemptId, operation = 'authorize') {
  fs.mkdirSync(support, { recursive: true })
  const identity = {
    name: 'fixture-server', source: 'configured', serverID: configuredMcpServerId,
    accountInstanceID: mcpAccountInstanceId, routeIdentity: codexMcpRouteIdentity,
  }
  fs.writeFileSync(path.join(support, 'extensions.json'), JSON.stringify({
    mcpServers: [{
      id: configuredMcpServerId,
      name: 'fixture-server', enabled: true, transport: 'stdio', command: '/bin/echo',
    }],
    pendingMCPReadiness: { byAccess: { codex_subscription: [{
      ...identity, changeId: attemptId,
    }] } },
    pendingMCPAuthorizations: { byAccess: { codex_subscription: [{
      ...identity, id: attemptId, operation, createdAt: '2026-08-13T12:00:00Z',
    }] } },
  }))
}

function writeCodexMcpCredentialMarker(fixture, changeId, serverId = configuredMcpServerId) {
  const codexHome = path.join(fixture.config, 'codex')
  fs.mkdirSync(codexHome, { recursive: true })
  fs.writeFileSync(
    path.join(codexHome, '.mechanician-mcp-credentials.generation'),
    `${JSON.stringify({
      schemaVersion: 1,
      revision: changeId,
      servers: { [serverId]: changeId },
    })}\n`,
    { mode: 0o600 },
  )
}

function codexMcpCredentialMarkerPath(fixture) {
  return path.join(fixture.config, 'codex', '.mechanician-mcp-credentials.generation')
}

function readCodexMcpCredentialMarker(fixture) {
  return JSON.parse(fs.readFileSync(codexMcpCredentialMarkerPath(fixture), 'utf8'))
}

function exactConfiguredMcpControl(type, id, overrides = {}) {
  return {
    type, id, name: 'fixture-server', attemptId: `${id}-attempt`, source: 'configured',
    serverId: configuredMcpServerId,
    accountInstanceId: mcpAccountInstanceId,
    routeIdentity: codexMcpRouteIdentity,
    operation: type === 'mcp_clear_auth' ? 'clear' : 'authorize',
    ...overrides,
  }
}

function makeTransportChild(onMessage) {
  const child = new EventEmitter()
  child.stdout = new PassThrough()
  child.stderr = new PassThrough()
  child.stdin = new EventEmitter()
  child.stdin.write = (text, callback) => {
    const message = JSON.parse(String(text))
    onMessage(message, child)
    queueMicrotask(() => callback?.())
    return true
  }
  child.kill = () => {
    queueMicrotask(() => child.emit('exit', 0, null))
    return true
  }
  child.send = (message) => child.stdout.write(`${JSON.stringify(message)}\n`)
  return child
}

async function startTransport(onMessage, onExit = () => {}, options = {}) {
  let child
  const app = new CodexAppServer({
    executable: '/fixture/codex',
    env: {},
    onExit,
    onRequest: options.onRequest,
    onActivityChange: options.onActivityChange,
    spawnProcess: () => {
      child = makeTransportChild((message, target) => {
        if (message.method === 'initialize') {
          queueMicrotask(() => target.send({ id: message.id, result: {} }))
          return
        }
        onMessage(message, target)
      })
      return child
    },
  })
  await app.start()
  return { app, child }
}

test('Codex transport reports both outbound and server-initiated in-flight work', async () => {
  const activity = []
  let releaseInbound
  const inboundGate = new Promise((resolve) => { releaseInbound = resolve })
  const { app, child } = await startTransport(() => {}, () => {}, {
    onActivityChange: (busy) => activity.push(busy),
    onRequest: async () => {
      await inboundGate
      return { accepted: true }
    },
  })
  activity.length = 0

  const outbound = app.request('thread/read', { threadId: 'thread-1' })
  assert.equal(app.hasInFlightWork, true)
  child.send({ id: 2, result: { thread: {} } })
  await outbound
  assert.equal(app.hasInFlightWork, false)

  child.send({ id: 9001, method: 'item/tool/call', params: {} })
  await delay(0)
  assert.equal(app.hasInFlightWork, true)
  releaseInbound()
  await delay(0)
  assert.equal(app.hasInFlightWork, false)
  assert.deepEqual(activity, [true, false, true, false])
  app.close()
})

test('Codex transport releases response acknowledgement only after a successful write', async () => {
  const written = []
  let acknowledged = 0
  const { app, child } = await startTransport((message) => written.push(message), () => {}, {
    onRequest: async () => {
      const result = { success: true, contentItems: [] }
      Object.defineProperty(result, CODEX_RESPONSE_WRITTEN, {
        value: () => { acknowledged += 1 }, enumerable: false,
      })
      return result
    },
  })

  child.send({ id: 9002, method: 'item/tool/call', params: {} })
  await delay(0)
  assert.equal(acknowledged, 1)
  assert.deepEqual(written.find((message) => message.id === 9002), {
    id: 9002, result: { success: true, contentItems: [] },
  })
  app.close()
})

test('Codex transport does not acknowledge a response whose pipe write fails', async () => {
  let failWrites = false
  let acknowledged = 0
  let exits = 0
  let child
  const app = new CodexAppServer({
    executable: '/fixture/codex', env: {}, onExit: () => { exits += 1 },
    onRequest: async () => {
      const result = { success: true }
      Object.defineProperty(result, CODEX_RESPONSE_WRITTEN, {
        value: () => { acknowledged += 1 }, enumerable: false,
      })
      return result
    },
    spawnProcess: () => {
      child = makeTransportChild((message, target) => {
        if (message.method === 'initialize') {
          queueMicrotask(() => target.send({ id: message.id, result: {} }))
        }
      })
      const ordinaryWrite = child.stdin.write
      child.stdin.write = (text, callback) => {
        if (!failWrites) return ordinaryWrite(text, callback)
        queueMicrotask(() => callback?.(new Error('fixture pipe closed')))
        return false
      }
      return child
    },
  })
  await app.start()
  failWrites = true
  child.send({ id: 9003, method: 'item/tool/call', params: {} })
  await delay(0)
  await delay(0)
  assert.equal(acknowledged, 0)
  assert.equal(exits, 1, 'the failed transport closes without forging acknowledgement')
  app.close()
})

test('Codex transport does not acknowledge a synchronous response write failure', async () => {
  let failWrites = false
  let acknowledged = 0
  let exits = 0
  let child
  const app = new CodexAppServer({
    executable: '/fixture/codex', env: {}, onExit: () => { exits += 1 },
    onRequest: async () => {
      const result = { success: true }
      Object.defineProperty(result, CODEX_RESPONSE_WRITTEN, {
        value: () => { acknowledged += 1 }, enumerable: false,
      })
      return result
    },
    spawnProcess: () => {
      child = makeTransportChild((message, target) => {
        if (message.method === 'initialize') {
          queueMicrotask(() => target.send({ id: message.id, result: {} }))
        }
      })
      const ordinaryWrite = child.stdin.write
      child.stdin.write = (text, callback) => {
        if (failWrites) throw new Error('synchronous fixture pipe failure')
        return ordinaryWrite(text, callback)
      }
      return child
    },
  })
  await app.start()
  failWrites = true
  child.send({ id: 9004, method: 'item/tool/call', params: {} })
  await delay(0)
  assert.equal(acknowledged, 0)
  assert.equal(exits, 1)

  // Closing removes the line reader. A late server request cannot reach the handler or synthesize
  // provider-boundary evidence after ownership has gone away.
  child.send({ id: 9005, method: 'item/tool/call', params: {} })
  await delay(0)
  assert.equal(acknowledged, 0)
})

test('Codex transport retains JSON-RPC code, data, method, and timeout metadata transiently', async () => {
  const { app } = await startTransport((message, child) => {
    if (message.method === 'turn/start') {
      queueMicrotask(() => child.send({
        id: message.id,
        error: {
          code: -32602,
          message: 'Invalid turn parameters.',
          data: { status: 400, requestId: 'codex_req_1', secret: 'transient-only' },
        },
      }))
    }
  })

  await assert.rejects(app.request('turn/start', { threadId: 'thread-1' }), (error) => {
    assert.equal(error.message, 'Invalid turn parameters.')
    assert.equal(error.providerType, 'json_rpc_error')
    assert.equal(error.code, -32602)
    assert.equal(error.method, 'turn/start')
    assert.deepEqual(error.data, {
      status: 400, requestId: 'codex_req_1', secret: 'transient-only',
    })
    return true
  })

  await assert.rejects(app.request('thread/read', { threadId: 'thread-1' }, 5), (error) => {
    assert.equal(error.providerType, 'app_server_timeout')
    assert.equal(error.code, 'app_server_timeout')
    assert.equal(error.method, 'thread/read')
    assert.equal(error.timeoutMs, 5)
    return true
  })
  app.close()
})

test('Codex transport reports an unexpected process failure once and retains pending method ownership', async () => {
  const exits = []
  const { app, child } = await startTransport(() => {}, (error) => exits.push(error))
  const pending = app.request('turn/start', { threadId: 'thread-1' })
  const processError = new Error('fixture process failed')
  processError.code = 'EPIPE'
  child.emit('error', processError)
  child.emit('exit', 17, null)

  await assert.rejects(pending, (error) => {
    assert.equal(error.message, 'fixture process failed')
    assert.equal(error.providerType, 'app_server_exit')
    assert.equal(error.code, 'EPIPE')
    assert.equal(error.method, 'turn/start')
    return true
  })
  assert.equal(exits.length, 1)
  assert.equal(exits[0].providerType, 'app_server_exit')
})

test('Codex transport closes once, disables readers, and kills a retained child on stdin EPIPE', async () => {
  const exits = []
  const { app, child } = await startTransport(() => {}, (error) => exits.push(error))
  let kills = 0
  child.kill = () => { kills += 1; return true }
  const pending = app.request('turn/start', { threadId: 'thread-1' })
  const brokenPipe = new Error('write EPIPE')
  brokenPipe.code = 'EPIPE'
  child.stdin.emit('error', brokenPipe)
  child.stdin.emit('error', brokenPipe)
  child.emit('exit', 17, null)

  await assert.rejects(pending, (error) => {
    assert.equal(error.message, 'write EPIPE')
    assert.equal(error.providerType, 'app_server_exit')
    assert.equal(error.code, 'EPIPE')
    assert.equal(error.method, 'turn/start')
    return true
  })
  assert.equal(exits.length, 1)
  assert.equal(kills, 1)
  assert.equal(child.stdout.destroyed, true)
  assert.equal(child.stderr.destroyed, true)
})

test('Codex transport escalates an unanswered graceful close to SIGKILL', async () => {
  const { app, child } = await startTransport(() => {})
  const signals = []
  child.kill = (signal) => {
    signals.push(signal)
    if (signal === 'SIGKILL') {
      child.signalCode = signal
      queueMicrotask(() => child.emit('exit', null, signal))
    }
    return true
  }

  app.close({ forceAfterMs: 5 })
  await delay(20)

  assert.deepEqual(signals, ['SIGTERM', 'SIGKILL'])
})

const fakeCodexSource = `#!${process.execPath}
import readline from 'node:readline'
import fs from 'node:fs'
import os from 'node:os'

const mode = process.env.CODEX_FIXTURE_MODE || 'retry-success'
if (process.argv.includes('logout')) {
  if (process.env.CODEX_FIXTURE_MCP_LOGOUT_FILE) {
    fs.writeFileSync(process.env.CODEX_FIXTURE_MCP_LOGOUT_FILE, process.argv.join('\\n'))
  }
  process.exit(0)
}
let fixtureStartOrdinal = 1
if (process.env.CODEX_FIXTURE_START_FILE) {
  try {
    fixtureStartOrdinal = fs.readFileSync(process.env.CODEX_FIXTURE_START_FILE, 'utf8')
      .split('\\n').filter(Boolean).length + 1
  } catch {}
}
if (process.env.CODEX_FIXTURE_PID_FILE) {
  fs.writeFileSync(process.env.CODEX_FIXTURE_PID_FILE, String(process.pid))
}
if (process.env.CODEX_FIXTURE_ENV_FILE) {
  fs.writeFileSync(process.env.CODEX_FIXTURE_ENV_FILE, JSON.stringify({
    openai: Object.hasOwn(process.env, 'OPENAI_API_KEY'),
    anthropic: Object.hasOwn(process.env, 'ANTHROPIC_API_KEY'),
    anthropicAuth: Object.hasOwn(process.env, 'ANTHROPIC_AUTH_TOKEN'),
    claudeOAuth: Object.hasOwn(process.env, 'CLAUDE_CODE_OAUTH_TOKEN'),
    apiDescriptor: Object.hasOwn(process.env, 'CLAUDE_CODE_API_KEY_FILE_DESCRIPTOR'),
    oauthDescriptor: Object.hasOwn(process.env, 'CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR'),
    codexHome: process.env.CODEX_HOME || null,
  }))
}
// Tests use the start ledger as their readiness barrier. Publish it only after every startup
// sidecar has the same process generation, or a loaded runner can observe the new start while the
// PID file still names the child that just exited.
if (process.env.CODEX_FIXTURE_START_FILE) {
  fs.appendFileSync(process.env.CODEX_FIXTURE_START_FILE, String(process.pid) + '\\n')
}
let threadCounter = 0
let turnCounter = 0
let startedTurns = 0
let firstTurnId = null
let earlyRequestTurnId = null
let earlyApprovalAccepted = false
let earlyToolSucceeded = false
let earlyRequestsCompleted = false
const interruptApprovalTurns = new Map()
let didLogout = false
let reviewTurnId = null
let reviewThreadId = null
const reviewWorkflowToolRequestId = 9701
const reviewShowToolRequestId = 9702
let reviewForgedToolReplies = 0
let threadReadCount = 0
let modelListCount = 0
let accountReadCount = 0
let accountReloadUpdateSent = false
let mcpOAuthLoginCount = 0
let skillsVersion = 1
let skillsChangeScheduled = false
let skillsListCount = 0
let readyExitScheduled = false
const turnsById = new Map()
const concurrentReusedTurns = []
const send = (message) => process.stdout.write(JSON.stringify(message) + '\\n')
const notify = (method, params) => send({ method, params })
const completeEarlyRequests = () => {
  if (earlyRequestsCompleted || !earlyApprovalAccepted || !earlyToolSucceeded) return
  earlyRequestsCompleted = true
  notify('turn/completed', {
    threadId: 'thread-1',
    turn: { id: earlyRequestTurnId, status: 'completed', items: [], error: null },
  })
}

readline.createInterface({ input: process.stdin }).on('line', (line) => {
  const message = JSON.parse(line)
  if (!Object.prototype.hasOwnProperty.call(message, 'id')) return
  if (!message.method && mode === 'early-requests') {
    if (message.id === 9101) earlyApprovalAccepted = message.result?.decision === 'accept'
    if (message.id === 9102) earlyToolSucceeded = message.result?.success === true
    completeEarlyRequests()
    return
  }
  if (!message.method && mode === 'early-approval-completion' && message.id === 9301) {
    process.stderr.write('EARLY_APPROVAL_RESPONSE=' + String(message.result?.decision) + '\\n')
    return
  }
  if (!message.method && mode === 'interrupt-approval' && interruptApprovalTurns.has(message.id)) {
    const turnId = interruptApprovalTurns.get(message.id)
    process.stderr.write(
      'INTERRUPT_APPROVAL_RESPONSE=' + turnId + ':' + String(message.result?.decision) + '\\n',
    )
    if (message.result?.decision === 'accept') {
      const turn = turnsById.get(turnId)
      if (turn) turn.status = 'completed'
      notify('turn/completed', {
        threadId: turn?.threadId,
        turn: { id: turnId, status: 'completed', items: [], error: null },
      })
    }
    return
  }
  if (!message.method && mode === 'review-workflow-forgery'
      && (message.id === reviewWorkflowToolRequestId
        || message.id === reviewShowToolRequestId)) {
    if (process.env.CODEX_FIXTURE_REVIEW_TOOL_FILE) {
      fs.appendFileSync(process.env.CODEX_FIXTURE_REVIEW_TOOL_FILE, JSON.stringify(message) + '\\n')
    }
    reviewForgedToolReplies += 1
    if (reviewForgedToolReplies === 2) {
      notify('turn/completed', {
        threadId: reviewThreadId,
        turn: { id: reviewTurnId, status: 'completed', items: [], error: null },
      })
    }
    return
  }
  switch (message.method) {
    case 'initialize':
      if (mode === 'startup-exit') process.exit(18)
      send({ id: message.id, result: {} })
      break
    case 'skills/list': {
      const skillCwd = message.params?.cwds?.[0] || process.cwd()
      skillsListCount += 1
      if (process.env.CODEX_FIXTURE_SKILLS_LOG_FILE) {
        fs.appendFileSync(
          process.env.CODEX_FIXTURE_SKILLS_LOG_FILE,
          JSON.stringify(message.params) + '\\n',
        )
      }
      const skill = (name, description, scope = 'user', enabled = true) => ({
        name, description, scope, enabled, path: skillCwd + '/SKILL.md',
      })
      if (mode === 'skills-overlap-failure') {
        if (skillsListCount === 1) {
          setTimeout(() => notify('skills/changed', {}), 10)
          setTimeout(() => send({ id: message.id, result: {
            data: [{
              cwd: skillCwd,
              skills: [skill('overlap-valid', 'Valid older request')],
              errors: [],
            }],
          } }), 1_500)
        } else {
          send({ id: message.id, error: {
            code: -32002, message: 'newer overlapping skills request failed',
          } })
        }
        break
      }
      if (mode === 'skills-cwd-race' && !skillCwd.endsWith('/next')) {
        setTimeout(() => send({ id: message.id, result: {
          data: [{ cwd: skillCwd, skills: [skill('from-old', 'Old workspace')], errors: [] }],
        } }), 150)
        break
      }
      if (mode === 'skills-cwd-failure' && skillCwd.endsWith('/next')) {
        send({ id: message.id, error: {
          code: -32002, message: 'new workspace skills failed',
        } })
        break
      }
      if (mode === 'skills-failure-retain' && skillsVersion === 2) {
        send({ id: message.id, error: { code: -32002, message: 'fixture skills failed' } })
        break
      }
      let skills = []
      if (mode === 'skills-authoritative') {
        skills = [
          skill('system-skill', 'System', 'system'),
          skill('repo-skill', 'Repository', 'repo'),
          skill('documents:documents', 'Plugin', 'user'),
          skill('disabled-skill', 'Disabled', 'user', false),
        ]
      } else if (mode === 'skills-changed') {
        skills = skillsVersion === 1
          ? [skill('initial-skill', 'Initial')]
          : [skill('updated-skill', 'Updated')]
      } else if (mode === 'skills-empty-refresh') {
        skills = skillsVersion === 1 ? [skill('removed-skill', 'Removed')] : []
      } else if (mode === 'skills-failure-retain') {
        skills = [skill('retained-skill', 'Retained')]
      } else if (mode === 'skills-cwd-race') {
        skills = [skill('from-next', 'New workspace', 'repo')]
      } else if (mode === 'skills-cwd-failure') {
        skills = [skill('from-old-before-failure', 'Old workspace', 'repo')]
      } else if (mode === 'skills-folderless') {
        skills = skillCwd === os.homedir()
          ? [skill('home-skill', 'Home')]
          : [skill('project-before-home', 'Project', 'repo')]
      }
      send({ id: message.id, result: {
        data: [{ cwd: skillCwd, skills, errors: [] }],
      } })
      if (['skills-changed', 'skills-empty-refresh', 'skills-failure-retain'].includes(mode)
          && !skillsChangeScheduled) {
        skillsChangeScheduled = true
        setTimeout(() => {
          skillsVersion = 2
          notify('skills/changed', {})
        }, 100)
      }
      break
    }
    case 'plugin/list':
      send({ id: message.id, result: { marketplaces: [] } })
      break
    case 'marketplace/add':
      send({ id: message.id, result: { alreadyAdded: true } })
      break
    case 'account/read':
      accountReadCount += 1
      if (process.env.CODEX_FIXTURE_ACCOUNT_READ_FILE) {
        fs.appendFileSync(
          process.env.CODEX_FIXTURE_ACCOUNT_READ_FILE,
          JSON.stringify({ ordinal: accountReadCount }) + '\\n',
        )
      }
      if (mode === 'logout-read-failure' && didLogout) {
        send({ id: message.id, error: { code: -32001, message: 'post-logout account read failed' } })
        break
      }
      if (mode === 'account-reload-read-failure' && accountReadCount > 1) {
        send({ id: message.id, error: { code: -32001, message: 'fixture account reload failed' } })
        break
      }
      if (mode === 'account-reload-notification-before-read' && accountReadCount > 1) {
        notify('account/updated', {
          authMode: 'chatgpt', planType: 'pro',
        })
        setTimeout(() => send({ id: message.id, result: {
          account: { type: 'chatgpt', planType: 'plus' },
        } }), 100)
        break
      }
      const fixtureAccountSignedOut = ['signed-out', 'ready-exit-loop-signed-out'].includes(mode)
        || (mode === 'ready-exit-loop-account-recovers' && fixtureStartOrdinal <= 3)
      send({ id: message.id, result: {
        account: fixtureAccountSignedOut ? null : { type: 'chatgpt', planType: 'plus' },
      } })
      if ((mode === 'ready-exit-loop-signed-out'
          || (mode === 'ready-exit-loop-account-recovers' && fixtureStartOrdinal <= 3))
          && !readyExitScheduled) {
        readyExitScheduled = true
        setTimeout(() => process.exit(20), 25)
      }
      break
    case 'account/login/start':
      process.stderr.write('ACCOUNT_LOGIN_START\\n')
      send({ id: message.id, result: { authUrl: 'https://example.test/codex-login' } })
      break
    case 'account/logout':
      didLogout = true
      send({ id: message.id, result: {} })
      break
    case 'mcpServer/oauth/login':
      mcpOAuthLoginCount += 1
      if (process.env.CODEX_FIXTURE_MCP_OAUTH_LOGIN_FILE) {
        fs.appendFileSync(
          process.env.CODEX_FIXTURE_MCP_OAUTH_LOGIN_FILE,
          JSON.stringify({
            name: message.params.name, ordinal: mcpOAuthLoginCount,
            pid: process.pid, processOrdinal: fixtureStartOrdinal,
          }) + '\\n',
        )
      }
      if (mode === 'oauth-start-exit') {
        setTimeout(() => process.exit(22), 5)
        break
      }
      send({ id: message.id, result: {
        authorizationUrl: 'https://example.test/codex-mcp-login',
      } })
      if (['oauth-complete-reload', 'oauth-complete-reload-fails',
        'oauth-complete-two-servers', 'oauth-complete-after-cancel',
        'oauth-complete-after-timeout', 'oauth-complete-while-turn-active'].includes(mode)
          || (mode === 'oauth-first-completes-second-holds' && mcpOAuthLoginCount === 1)) {
        setTimeout(() => notify('mcpServer/oauthLogin/completed', {
          name: message.params.name,
          success: true,
        }), ['oauth-complete-after-cancel', 'oauth-complete-after-timeout'].includes(mode)
          ? Number(process.env.CODEX_FIXTURE_OAUTH_COMPLETION_DELAY_MS || 250) : 10)
      }
      break
    case 'config/mcpServer/reload':
      if (process.env.CODEX_FIXTURE_MCP_RELOAD_FILE) {
        fs.writeFileSync(process.env.CODEX_FIXTURE_MCP_RELOAD_FILE, 'reload-started')
      }
      if (process.env.CODEX_FIXTURE_MCP_RELOAD_RELEASE_FILE
          && !fs.existsSync(process.env.CODEX_FIXTURE_MCP_RELOAD_RELEASE_FILE)) {
        const waitForReloadRelease = () => {
          if (fs.existsSync(process.env.CODEX_FIXTURE_MCP_RELOAD_RELEASE_FILE)) {
            send({ id: message.id, result: {} })
          } else setTimeout(waitForReloadRelease, 5)
        }
        waitForReloadRelease()
      } else if (['oauth-complete-reload', 'clear-auth-reload'].includes(mode)) {
        setTimeout(() => send({ id: message.id, result: {} }), 150)
      } else if (mode === 'oauth-complete-reload-fails') {
        setTimeout(() => send({
          id: message.id,
          error: { code: -32003, message: 'fixture MCP reload failed' },
        }), 20)
      } else {
        send({ id: message.id, result: {} })
      }
      break
    case 'mcpServerStatus/list':
      if (process.env.CODEX_FIXTURE_MCP_STATUS_OBSERVATION_FILE) {
        let marker = null
        try {
          const markerPath = process.env.CODEX_FIXTURE_MCP_MARKER_PATH
            || process.env.CODEX_HOME + '/.mechanician-mcp-credentials.generation'
          marker = fs.readFileSync(markerPath, 'utf8')
        } catch {}
        fs.appendFileSync(
          process.env.CODEX_FIXTURE_MCP_STATUS_OBSERVATION_FILE,
          JSON.stringify({ marker }) + '\\n',
        )
      }
      const mcpStatusNames = ['oauth-complete-two-servers',
        'oauth-first-completes-second-holds'].includes(mode)
        ? ['fixture-server', 'fixture-server-two'] : ['fixture-server']
      let fixtureStatusToolsReady = true
      if (process.env.CODEX_FIXTURE_MCP_STATUS_TOOLS_FILE) {
        try {
          fixtureStatusToolsReady = fs.readFileSync(
            process.env.CODEX_FIXTURE_MCP_STATUS_TOOLS_FILE, 'utf8').trim() === 'ready'
        } catch { fixtureStatusToolsReady = false }
      }
      send({ id: message.id, result: {
        data: mcpStatusNames.map((name) => ({
          name,
          serverInfo: { name, version: '1' },
          authStatus: 'oAuth',
          ...(mode === 'mcp-status-no-inventory' ? {} : {
            tools: mode === 'mcp-status-zero-tools' || !fixtureStatusToolsReady
              ? {} : { fixture_tool: {} },
          }),
        })),
      } })
      break
    case 'model/list':
      modelListCount += 1
      if (mode === 'catalog-error') {
        send({ id: message.id, error: { code: -32002, message: 'fixture catalog failed' } })
        break
      }
      const modelListResponse = { id: message.id, result: {
        data: mode === 'catalog-empty' ? [] : [{
          id: 'gpt-fixture', displayName: 'Fixture', isDefault: true,
          supportedReasoningEfforts: [
            { reasoningEffort: 'low' }, { reasoningEffort: 'high' },
          ],
        }],
        nextCursor: null,
      } }
      if (mode === 'account-reload-notification-during-catalog' && accountReadCount > 1
          && !accountReloadUpdateSent) {
        accountReloadUpdateSent = true
        notify('account/updated', {
          authMode: 'chatgpt', planType: 'pro',
        })
        setTimeout(() => send(modelListResponse), 100)
      } else if (mode === 'residency-slow-catalog' && modelListCount > 1) {
        setTimeout(() => send(modelListResponse), 120)
      } else {
        send(modelListResponse)
      }
      if (['ready-exit-loop', 'ready-exit-stability-reset'].includes(mode)
          && !readyExitScheduled) {
        readyExitScheduled = true
        // Exit only after initialize, account/read, and the startup catalog all answered. This is
        // the dangerous shape for a restart loop: every child looks healthy long enough to reset a
        // naive consecutive-failure counter, then disappears immediately afterward.
        const exitDelay = mode === 'ready-exit-stability-reset'
          ? (fixtureStartOrdinal === 1 ? 25 : fixtureStartOrdinal === 2 ? 150 : null)
          : 25
        if (exitDelay !== null) setTimeout(() => process.exit(20), exitDelay)
      }
      break
    case 'thread/start': {
      if (process.env.CODEX_FIXTURE_THREAD_START_LOG_FILE) {
        fs.appendFileSync(
          process.env.CODEX_FIXTURE_THREAD_START_LOG_FILE,
          JSON.stringify(message.params) + '\\n',
        )
      }
      if (process.env.CODEX_FIXTURE_THREAD_PROCESS_FILE) {
        fs.appendFileSync(
          process.env.CODEX_FIXTURE_THREAD_PROCESS_FILE,
          JSON.stringify({
            pid: process.pid, processOrdinal: fixtureStartOrdinal, params: message.params,
          }) + '\\n',
        )
      }
      const threadId = 'thread-' + (++threadCounter)
      send({ id: message.id, result: {
        model: process.env.CODEX_FIXTURE_START_MODEL || 'gpt-fixture',
        modelProvider: 'openai',
        thread: { id: threadId },
      } })
      break
    }
    case 'thread/resume':
      if (process.env.CODEX_FIXTURE_RESUME_FILE) {
        fs.writeFileSync(process.env.CODEX_FIXTURE_RESUME_FILE, JSON.stringify(message.params))
      }
      if (process.env.CODEX_FIXTURE_RESUME_LOG_FILE) {
        fs.appendFileSync(
          process.env.CODEX_FIXTURE_RESUME_LOG_FILE,
          JSON.stringify(message.params) + '\\n',
        )
      }
      if (process.env.CODEX_FIXTURE_REORDER_RESUME_MODEL === '1') {
        notify('thread/settings/updated', {
          threadId: message.params.threadId,
          threadSettings: {
            model: 'gpt-notification-newer',
            modelProvider: 'openai',
          },
        })
        setTimeout(() => send({ id: message.id, result: {
          model: 'gpt-response-stale',
          modelProvider: 'openai',
          thread: { id: message.params.threadId },
        } }), 50)
      } else {
        send({ id: message.id, result: {
          model: process.env.CODEX_FIXTURE_RESUME_MODEL
            || message.params.model
            || 'gpt-fixture',
          modelProvider: 'openai',
          thread: { id: message.params.threadId },
        } })
      }
      break
    case 'thread/read': {
      threadReadCount += 1
      if (mode === 'reconcile-timeout') break
      const turn = [...turnsById.values()]
        .find((candidate) => candidate.threadId === message.params.threadId) || null
      if (mode === 'reconcile-quiet' && turn && threadReadCount >= 2) {
        turn.status = 'completed'
      }
      if (mode === 'reconcile-waits' && turn && threadReadCount >= 3) {
        turn.status = 'completed'
      }
      const omitExpectedTurn = mode === 'reconcile-orphan' || mode === 'reconcile-mismatch'
      const active = turn?.status === 'inProgress'
      send({
        id: message.id,
        result: {
          thread: {
            id: message.params.threadId,
            status: mode === 'reconcile-orphan'
              ? { type: 'idle' }
              : mode === 'reconcile-mismatch'
              ? { type: 'active', activeFlags: [] }
              : active
                ? {
                    type: 'active',
                    activeFlags: mode === 'reconcile-waits'
                      ? [threadReadCount === 1 ? 'waitingOnApproval' : 'waitingOnUserInput']
                      : [],
                  }
                : { type: 'idle' },
            turns: message.params.includeTurns && turn && !omitExpectedTurn ? [{
              id: turn.id, status: turn.status, items: turn.items || [],
              itemsView: 'full', error: turn.error || null,
            }] : [],
          },
        },
      })
      break
    }
    case 'turn/start': {
      if (process.env.CODEX_FIXTURE_TURN_FILE) {
        fs.appendFileSync(
          process.env.CODEX_FIXTURE_TURN_FILE,
          JSON.stringify(message.params) + '\\n',
        )
      }
      const turnId = 'codex-turn-' + (++turnCounter)
      startedTurns += 1
      if (!firstTurnId) firstTurnId = turnId
      turnsById.set(turnId, {
        id: turnId, threadId: message.params.threadId, status: 'inProgress', items: [],
      })
      if (mode === 'reconcile-completed') {
        const turn = turnsById.get(turnId)
        turn.status = 'completed'
        turn.items = [
          { type: 'agentMessage', id: 'recovered-message', text: 'Recovered final.' },
          {
            type: 'commandExecution', id: 'recovered-command', command: 'git status',
            cwd: message.params.cwd, status: 'completed', exitCode: 0,
          },
        ]
      }
      const response = { id: message.id, result: { turn: { id: turnId } } }
      if (mode === 'early-requests') {
        earlyRequestTurnId = turnId
        const approval = {
          id: 9101,
          method: 'item/commandExecution/requestApproval',
          params: {
            threadId: message.params.threadId, turnId,
            itemId: 'early-command', command: 'echo fixture', cwd: message.params.cwd,
          },
        }
        const tool = {
          id: 9102,
          method: 'item/tool/call',
          params: {
            threadId: message.params.threadId, turnId, callId: 'early-tool',
            tool: 'CreateOrUpdateArtifact',
            arguments: { type: 'markdown', title: 'Early tool', source: 'early output' },
          },
        }
        process.stdout.write(
          JSON.stringify(response) + '\\n' + JSON.stringify(approval) + '\\n' + JSON.stringify(tool) + '\\n',
        )
        break
      }
      if (mode === 'early-approval-completion') {
        const approval = {
          id: 9301,
          method: 'item/commandExecution/requestApproval',
          params: {
            threadId: message.params.threadId, turnId,
            itemId: 'unanswered-command', command: 'echo fixture', cwd: message.params.cwd,
          },
        }
        const completion = {
          method: 'turn/completed',
          params: {
            threadId: message.params.threadId,
            turn: { id: turnId, status: 'completed', items: [], error: null },
          },
        }
        process.stdout.write(
          JSON.stringify(response) + '\\n' + JSON.stringify(approval) + '\\n' + JSON.stringify(completion) + '\\n',
        )
        break
      }
      if (mode === 'interrupt-approval') {
        const requestId = 9400 + startedTurns
        interruptApprovalTurns.set(requestId, turnId)
        const approval = {
          id: requestId,
          method: 'item/commandExecution/requestApproval',
          params: {
            threadId: message.params.threadId, turnId,
            itemId: 'interrupt-command-' + startedTurns,
            command: 'echo interrupt-' + startedTurns,
            cwd: message.params.cwd,
          },
        }
        process.stdout.write(JSON.stringify(response) + '\\n' + JSON.stringify(approval) + '\\n')
        break
      }
      if (mode === 'early-pressure') {
        const messages = []
        for (let index = 0; index < 150; index += 1) {
          messages.push({
            method: 'item/agentMessage/delta',
            params: {
              threadId: message.params.threadId, turnId,
              itemId: 'early-' + index, delta: String(index) + ':' + 'x'.repeat(4096),
            },
          })
        }
        messages.push({
          method: 'turn/completed',
          params: {
            threadId: message.params.threadId,
            turn: { id: turnId, status: 'completed', items: [], error: null },
          },
        })
        messages.push(response)
        process.stdout.write(messages.map((entry) => JSON.stringify(entry)).join('\\n') + '\\n')
        break
      }
      if (mode === 'early-terminal-overflow') {
        const completion = {
          method: 'turn/completed',
          params: {
            threadId: message.params.threadId,
            turn: {
              id: turnId, status: 'failed', items: [],
              error: { message: 'z'.repeat(300 * 1024) },
            },
          },
        }
        process.stdout.write(JSON.stringify(completion) + '\\n' + JSON.stringify(response) + '\\n')
        break
      }
      if (mode === 'early-completion') {
        const completion = {
          method: 'turn/completed',
          params: {
            threadId: message.params.threadId,
            turn: { id: turnId, status: 'completed', items: [], error: null },
          },
        }
        process.stdout.write(JSON.stringify(response) + '\\n' + JSON.stringify(completion) + '\\n')
        setTimeout(() => notify('item/agentMessage/delta', {
          threadId: message.params.threadId, turnId,
          itemId: 'late-after-completion', delta: 'LATE',
        }), 20)
        break
      }
      if (mode === 'exit-after-start-response') {
        send(response)
        setTimeout(() => process.exit(19), 5)
        break
      }
      send(response)
      if (mode === 'reused-child-followup-concurrent' && startedTurns > 1) {
        concurrentReusedTurns.push({
          threadId: message.params.threadId, turnId, cwd: message.params.cwd,
        })
        if (concurrentReusedTurns.length === 2) {
          setTimeout(() => {
            const childThreadId = 'thread-reused-child'
            const childPath = '/root/reused_child'
            const owner = concurrentReusedTurns.find((turn) => (
              turn.threadId === 'thread-reused-parent'
            ))
            const other = concurrentReusedTurns.find((turn) => turn !== owner)
            notify('turn/started', {
              threadId: childThreadId,
              turn: {
                id: 'codex-reused-child-concurrent-turn', status: 'inProgress',
                items: [], error: null,
              },
            })
            const priorLifecycle = [
              ['reused-child-concurrent-prior-started', 'started'],
              ['reused-child-concurrent-prior-terminal', 'completed'],
              ['reused-child-concurrent-prior-interacted', 'interacted'],
            ]
            for (const [id, kind] of priorLifecycle) {
              notify('item/completed', {
                threadId: other.threadId, turnId: other.turnId,
                item: {
                  type: 'subAgentActivity', id, kind,
                  agentThreadId: childThreadId, agentPath: childPath,
                },
              })
            }
            const interacted = {
              type: 'subAgentActivity', id: 'reused-child-concurrent-followup',
              kind: 'interacted', agentThreadId: childThreadId, agentPath: childPath,
            }
            notify('item/completed', {
              threadId: owner.threadId, turnId: owner.turnId,
              item: interacted,
            })
            // The nonowner's deferred item tombstones survive the owner's bind. A full thread/read
            // replay, including both old boundaries and both Interacted identities, stays inert.
            for (const [id, kind] of priorLifecycle) {
              notify('item/completed', {
                threadId: other.threadId, turnId: other.turnId,
                item: {
                  type: 'subAgentActivity', id, kind,
                  agentThreadId: childThreadId, agentPath: childPath,
                },
              })
            }
            notify('item/completed', {
              threadId: other.threadId, turnId: other.turnId, item: interacted,
            })
            // A first-seen stale item can arrive after the owner consumed the early-turn buffer.
            // It must neither publish on nor register the nonowner, whose root finishes first.
            notify('item/completed', {
              threadId: other.threadId, turnId: other.turnId,
              item: {
                type: 'subAgentActivity', id: 'reused-child-concurrent-distinct-late-stale',
                kind: 'started', agentThreadId: childThreadId, agentPath: childPath,
              },
            })
            notify('turn/completed', {
              threadId: other.threadId,
              turn: { id: other.turnId, status: 'completed', items: [], error: null },
            })
            // Prove the nonowner terminal did not erase the authoritative child state. Both this
            // post-terminal metadata and the child's terminal must still route to the owner.
            notify('thread/settings/updated', {
              threadId: childThreadId,
              threadSettings: { model: 'gpt-concurrent-owner-survives' },
            })
            notify('turn/completed', {
              threadId: childThreadId,
              turn: {
                id: 'codex-reused-child-concurrent-turn', status: 'completed',
                items: [], error: null,
              },
            })
            notify('turn/completed', {
              threadId: owner.threadId,
              turn: { id: owner.turnId, status: 'completed', items: [], error: null },
            })
          }, 10)
        }
        break
      }
      if (mode === 'skills-turn-active') {
        notify('skills/changed', {})
        break
      }
      setTimeout(() => {
        if (mode === 'reconcile-completed') {
          // Deliver item completions but deliberately drop turn/completed. The later
          // thread/read replay must recover the terminal without duplicating these items.
          for (const item of turnsById.get(turnId)?.items || []) {
            notify('item/completed', {
              threadId: message.params.threadId, turnId, item,
            })
          }
          return
        }
        if (mode === 'reconcile-quiet' || mode === 'reconcile-waits' ||
            mode === 'reconcile-timeout' || mode === 'reconcile-orphan' ||
            mode === 'reconcile-mismatch' || mode === 'interrupt-no-active-terminal' ||
            mode === 'residency-hold') return
        if (mode === 'image-generation') {
          const image = {
            type: 'imageGeneration', id: 'generated-image-1', status: 'completed',
            result: 'Generated image.', revisedPrompt: 'watercolor fox',
            savedPath: process.env.CODEX_FIXTURE_IMAGE_PATH,
          }
          // Completion can be the first item notification after transport recovery. The daemon
          // must materialize the card there, and its idempotency fences must suppress replay.
          notify('item/completed', { threadId: message.params.threadId, turnId, item: image })
          notify('item/completed', { threadId: message.params.threadId, turnId, item: image })
          notify('item/started', {
            threadId: message.params.threadId, turnId,
            item: { ...image, status: 'inProgress' },
          })
          notify('turn/completed', {
            threadId: message.params.threadId,
            turn: { id: turnId, status: 'completed', items: [], error: null },
          })
          return
        }
        if (mode === 'duplicate-reordered') {
          const messageItem = {
            type: 'agentMessage', id: 'reordered-message', text: 'Exactly once.',
          }
          const commandItem = {
            type: 'commandExecution', id: 'reordered-command', command: 'git status',
            cwd: message.params.cwd, status: 'completed', exitCode: 0,
          }
          // Completion-before-start, duplicates, and a late start exercise item idempotency.
          for (const item of [messageItem, messageItem, commandItem, commandItem]) {
            notify('item/completed', { threadId: message.params.threadId, turnId, item })
          }
          notify('item/started', {
            threadId: message.params.threadId, turnId,
            item: { ...commandItem, status: 'inProgress' },
          })
          notify('turn/started', {
            threadId: message.params.threadId,
            turn: { id: turnId, status: 'inProgress', items: [], error: null },
          })
          const completed = {
            threadId: message.params.threadId,
            turn: { id: turnId, status: 'completed', items: [], error: null },
          }
          notify('turn/completed', completed)
          notify('turn/completed', completed)
          return
        }
        if (mode === 'send-input-generation-dedupe') {
          const childThreadId = 'thread-send-input-child'
          const childPath = '/root/send_input_child'
          const priorStarted = {
            type: 'subAgentActivity', id: 'send-input-prior-started', kind: 'started',
            agentThreadId: childThreadId, agentPath: childPath,
          }
          const priorTerminal = {
            type: 'subAgentActivity', id: 'send-input-prior-terminal', kind: 'completed',
            agentThreadId: childThreadId, agentPath: childPath,
          }
          const priorInteracted = {
            type: 'subAgentActivity', id: 'send-input-prior-interacted', kind: 'interacted',
            agentThreadId: childThreadId, agentPath: childPath,
          }
          if (startedTurns === 1) {
            for (const item of [priorStarted, priorInteracted, priorTerminal]) {
              notify('item/completed', {
                threadId: message.params.threadId, turnId, item,
              })
            }
            notify('turn/completed', {
              threadId: childThreadId,
              turn: {
                id: 'send-input-prior-child-turn', status: 'completed',
                items: [], error: null,
              },
            })
            notify('turn/completed', {
              threadId: message.params.threadId,
              turn: { id: turnId, status: 'completed', items: [], error: null },
            })
            return
          }

          // The reused receiver starts before the later root has a lifecycle card. Prior-generation
          // thread/read items are deferred until the first authoritative legacy boundary owns it.
          notify('turn/started', {
            threadId: childThreadId,
            turn: {
              id: 'send-input-legacy-child-turn', status: 'inProgress',
              items: [], error: null,
            },
          })
          for (const item of [priorStarted, priorTerminal, priorInteracted]) {
            notify('item/completed', {
              threadId: message.params.threadId, turnId, item,
            })
          }
          const startedAndCompleted = {
            type: 'collabAgentToolCall', id: 'send-input-started-and-completed',
            tool: 'sendInput', receiverThreadIds: [childThreadId],
            prompt: 'started and completed retask',
            agentsStates: { [childThreadId]: { status: 'running' } },
          }
          notify('item/started', {
            threadId: message.params.threadId, turnId, item: startedAndCompleted,
          })
          notify('item/completed', {
            threadId: childThreadId, turnId: 'send-input-child-turn',
            item: {
              type: 'commandExecution', id: 'send-input-intervening-command',
              command: 'git status', cwd: message.params.cwd,
              status: 'completed', exitCode: 0,
            },
          })
          notify('item/completed', {
            threadId: message.params.threadId, turnId, item: startedAndCompleted,
          })
          // Consuming the early turn must not let a later full thread/read replay leak the exact
          // prior started/completed lifecycle, or reopen the replayed Interacted generation.
          for (const item of [priorStarted, priorTerminal, priorInteracted]) {
            notify('item/completed', {
              threadId: message.params.threadId, turnId, item,
            })
          }
          // Same provider item replayed as thread/read would report it: useful metadata remains,
          // but this is not a third lifecycle boundary.
          notify('item/completed', {
            threadId: message.params.threadId, turnId, item: startedAndCompleted,
          })

          const completedOnly = {
            type: 'collabAgentToolCall', id: 'send-input-completed-only',
            tool: 'sendInput', receiverThreadIds: [childThreadId],
            prompt: 'completed only retask',
            agentsStates: { [childThreadId]: { status: 'running' } },
          }
          notify('item/completed', {
            threadId: message.params.threadId, turnId, item: completedOnly,
          })
          notify('item/completed', {
            threadId: message.params.threadId, turnId, item: completedOnly,
          })

          notify('turn/completed', {
            threadId: childThreadId,
            turn: {
              id: 'send-input-legacy-child-turn', status: 'completed',
              items: [], error: null,
            },
          })

          // Interacted followed by plaintext sendInput is one provider turn and therefore one
          // Activity generation. A real child tool can arrive between the two parent shapes.
          notify('turn/started', {
            threadId: childThreadId,
            turn: {
              id: 'send-input-v2-forward-turn', status: 'inProgress',
              items: [], error: null,
            },
          })
          const forwardInteracted = {
            type: 'subAgentActivity', id: 'send-input-v2-forward-interacted',
            kind: 'interacted', agentThreadId: childThreadId, agentPath: childPath,
          }
          notify('item/completed', {
            threadId: message.params.threadId, turnId, item: forwardInteracted,
          })
          notify('item/completed', {
            threadId: childThreadId, turnId: 'send-input-v2-forward-turn',
            item: {
              type: 'commandExecution', id: 'send-input-v2-forward-command',
              command: 'git diff --check', cwd: message.params.cwd,
              status: 'completed', exitCode: 0,
            },
          })
          notify('turn/completed', {
            threadId: childThreadId,
            turn: {
              id: 'send-input-v2-forward-turn', status: 'completed',
              items: [], error: null,
            },
          })
          const forwardUpgrade = {
            type: 'collabAgentToolCall', id: 'send-input-v2-forward-upgrade',
            tool: 'sendInput', receiverThreadIds: [childThreadId],
            prompt: 'v2 plaintext upgrade',
            agentsStates: { [childThreadId]: { status: 'running' } },
          }
          notify('item/completed', {
            threadId: message.params.threadId, turnId, item: forwardUpgrade,
          })
          notify('item/completed', {
            threadId: message.params.threadId, turnId, item: forwardUpgrade,
          })

          // Terminal clears the mixed-shape handshake. This later sendInput is a genuine retask,
          // and its following Interacted item is the reverse-order form of the same provider turn.
          const reverseSendInput = {
            type: 'collabAgentToolCall', id: 'send-input-v2-reverse-send-input',
            tool: 'sendInput', receiverThreadIds: [childThreadId],
            prompt: 'post-terminal reverse retask',
            agentsStates: { [childThreadId]: { status: 'running' } },
          }
          notify('item/started', {
            threadId: message.params.threadId, turnId, item: reverseSendInput,
          })
          notify('turn/started', {
            threadId: childThreadId,
            turn: {
              id: 'send-input-v2-reverse-turn', status: 'inProgress',
              items: [], error: null,
            },
          })
          notify('item/completed', {
            threadId: childThreadId, turnId: 'send-input-v2-reverse-turn',
            item: {
              type: 'commandExecution', id: 'send-input-v2-reverse-command',
              command: 'swift test', cwd: message.params.cwd,
              status: 'completed', exitCode: 0,
            },
          })
          notify('turn/completed', {
            threadId: childThreadId,
            turn: {
              id: 'send-input-v2-reverse-turn', status: 'completed',
              items: [], error: null,
            },
          })
          const reverseInteracted = {
            type: 'subAgentActivity', id: 'send-input-v2-reverse-interacted',
            kind: 'interacted', agentThreadId: childThreadId, agentPath: childPath,
          }
          notify('item/completed', {
            threadId: message.params.threadId, turnId, item: reverseInteracted,
          })
          notify('item/completed', {
            threadId: message.params.threadId, turnId, item: reverseSendInput,
          })
          notify('turn/completed', {
            threadId: message.params.threadId,
            turn: { id: turnId, status: 'completed', items: [], error: null },
          })
          return
        }
        if (mode === 'reused-child-followup'
            || mode === 'reused-child-followup-terminal-race'
            || mode === 'reused-child-followup-concurrent') {
          const childThreadId = 'thread-reused-child'
          const childPath = '/root/reused_child'
          if (startedTurns === 1) {
            notify('item/completed', {
              threadId: message.params.threadId, turnId,
              item: {
                type: 'subAgentActivity', id: 'reused-child-initial', kind: 'started',
                agentThreadId: childThreadId, agentPath: childPath,
              },
            })
            if (mode === 'reused-child-followup-concurrent') {
              notify('item/completed', {
                threadId: message.params.threadId, turnId,
                item: {
                  type: 'subAgentActivity', id: 'reused-child-concurrent-prior-interacted',
                  kind: 'interacted', agentThreadId: childThreadId, agentPath: childPath,
                },
              })
            }
            notify('turn/completed', {
              threadId: childThreadId,
              turn: {
                id: 'codex-reused-child-first-turn', status: 'completed',
                items: [], error: null,
              },
            })
          } else {
            // MultiAgentV2 followup_task starts the receiver directly. Its turn can race ahead of
            // the sender's Interacted item, while a replayed terminal observation from the prior
            // generation has already reached this later Mechanician turn.
            notify('turn/started', {
              threadId: childThreadId,
              turn: {
                id: 'codex-reused-child-followup-turn', status: 'inProgress',
                items: [], error: null,
              },
            })
            notify('item/completed', {
              threadId: message.params.threadId, turnId,
              item: {
                type: 'subAgentActivity', id: 'reused-child-prior-started',
                kind: 'started', agentThreadId: childThreadId, agentPath: childPath,
              },
            })
            notify('item/completed', {
              threadId: message.params.threadId, turnId,
              item: {
                type: 'subAgentActivity', id: 'reused-child-prior-terminal',
                kind: 'completed', agentThreadId: childThreadId, agentPath: childPath,
              },
            })
            if (mode === 'reused-child-followup-terminal-race') {
              notify('item/completed', {
                threadId: childThreadId, turnId: 'codex-reused-child-followup-turn',
                item: {
                  type: 'commandExecution', id: 'reused-child-followup-command',
                  command: 'git status', cwd: message.params.cwd,
                  status: 'completed', exitCode: 0,
                },
              })
              notify('turn/completed', {
                threadId: childThreadId,
                turn: {
                  id: 'codex-reused-child-followup-turn', status: 'failed',
                  items: [], error: { message: 'child failed' },
                },
              })
            }
            const interacted = {
              type: 'subAgentActivity', id: 'reused-child-followup', kind: 'interacted',
              agentThreadId: childThreadId, agentPath: childPath,
            }
            notify('item/completed', {
              threadId: message.params.threadId, turnId, item: interacted,
            })
            for (const [id, kind] of [
              ['reused-child-prior-started', 'started'],
              ['reused-child-prior-terminal', 'completed'],
            ]) {
              notify('item/completed', {
                threadId: message.params.threadId, turnId,
                item: {
                  type: 'subAgentActivity', id, kind,
                  agentThreadId: childThreadId, agentPath: childPath,
                },
              })
            }
            if (mode === 'reused-child-followup') {
              notify('item/completed', {
                threadId: childThreadId, turnId: 'codex-reused-child-followup-turn',
                item: {
                  type: 'commandExecution', id: 'reused-child-followup-command',
                  command: 'git status', cwd: message.params.cwd,
                  status: 'completed', exitCode: 0,
                },
              })
            }
            // A replay of the same Interacted item is metadata, not another generation.
            notify('item/completed', {
              threadId: message.params.threadId, turnId, item: interacted,
            })
          }
          notify('turn/completed', {
            threadId: message.params.threadId,
            turn: { id: turnId, status: 'completed', items: [], error: null },
          })
          return
        }
        if (mode === 'child-metrics-early-pressure') {
          const childThreadId = 'thread-child-pressure'
          const childTurnId = 'codex-child-pressure-turn'
          for (let index = 0; index < 140; index += 1) {
            notify('item/started', {
              threadId: childThreadId, turnId: childTurnId,
              item: { type: 'commandExecution', id: 'early-command-' + index },
            })
          }
          notify('item/completed', {
            threadId: message.params.threadId, turnId,
            item: {
              type: 'subAgentActivity', id: 'pressure-activity-start', kind: 'started',
              agentThreadId: childThreadId, agentPath: '/root/pressure_child',
            },
          })
          notify('thread/tokenUsage/updated', {
            threadId: childThreadId, turnId: childTurnId,
            tokenUsage: {
              total: { totalTokens: 777, inputTokens: 700, cachedInputTokens: 0, outputTokens: 77, reasoningOutputTokens: 0 },
              last: { totalTokens: 777, inputTokens: 700, cachedInputTokens: 0, outputTokens: 77, reasoningOutputTokens: 0 },
              modelContextWindow: 128_000,
            },
          })
          notify('item/completed', {
            threadId: message.params.threadId, turnId,
            item: {
              type: 'subAgentActivity', id: 'pressure-activity-done', kind: 'completed',
              agentThreadId: childThreadId, agentPath: '/root/pressure_child',
            },
          })
          notify('turn/completed', {
            threadId: message.params.threadId,
            turn: { id: turnId, status: 'completed', items: [], error: null },
          })
        } else if (mode === 'child-metrics-nested') {
          const childThreadId = 'thread-child-parent'
          const grandchildThreadId = 'thread-child-grandchild'
          notify('item/completed', {
            threadId: message.params.threadId, turnId,
            item: {
              type: 'subAgentActivity', id: 'parent-child-start', kind: 'started',
              agentThreadId: childThreadId, agentPath: '/root/parent_child',
            },
          })
          // This lifecycle item arrives on the child thread. It must create a second
          // Agents row without letting any of the child's ordinary output leak into
          // the parent transcript.
          notify('item/completed', {
            threadId: childThreadId, turnId: 'codex-child-parent-turn',
            item: {
              type: 'subAgentActivity', id: 'grandchild-start', kind: 'started',
              agentThreadId: grandchildThreadId,
              agentPath: '/root/parent_child/grandchild',
            },
          })
          notify('thread/tokenUsage/updated', {
            threadId: grandchildThreadId, turnId: 'codex-grandchild-turn',
            tokenUsage: {
              total: { totalTokens: 333, inputTokens: 300, cachedInputTokens: 0, outputTokens: 33, reasoningOutputTokens: 0 },
              last: { totalTokens: 333, inputTokens: 300, cachedInputTokens: 0, outputTokens: 33, reasoningOutputTokens: 0 },
              modelContextWindow: 128_000,
            },
          })
          notify('item/started', {
            threadId: grandchildThreadId, turnId: 'codex-grandchild-turn',
            item: {
              type: 'commandExecution', id: 'grandchild-command', command: 'git status',
              cwd: message.params.cwd, status: 'inProgress',
            },
          })
          notify('item/completed', {
            threadId: grandchildThreadId, turnId: 'codex-grandchild-turn',
            item: {
              type: 'commandExecution', id: 'grandchild-command', command: 'git status',
              cwd: message.params.cwd, status: 'completed', exitCode: 0,
            },
          })
          notify('item/completed', {
            threadId: grandchildThreadId, turnId: 'codex-grandchild-turn',
            item: {
              type: 'agentMessage', id: 'grandchild-final',
              author: '/root/parent_child/grandchild',
              text: 'Message Type: FINAL_ANSWER\\nTask name: grandchild\\nPayload:\\nDone.',
            },
          })
          notify('item/completed', {
            threadId: childThreadId, turnId: 'codex-child-parent-turn',
            item: {
              type: 'agentMessage', id: 'parent-child-final',
              author: '/root/parent_child',
              text: 'Message Type: FINAL_ANSWER\\nTask name: parent_child\\nPayload:\\nDone.',
            },
          })
          notify('turn/completed', {
            threadId: message.params.threadId,
            turn: { id: turnId, status: 'completed', items: [], error: null },
          })
        } else if (mode === 'child-metrics') {
          const childThreadId = 'thread-child-metrics'
          const childTurnId = 'codex-child-turn-1'
          // Child metrics can race ahead of the parent's first subAgentActivity item.
          notify('thread/settings/updated', {
            threadId: childThreadId,
            threadSettings: { model: 'gpt-child-initial' },
          })
          notify('item/started', {
            threadId: childThreadId, turnId: childTurnId,
            item: { type: 'dynamicToolCall', id: 'child-early-tool', tool: 'fixture' },
          })
          notify('thread/tokenUsage/updated', {
            threadId: childThreadId, turnId: childTurnId,
            tokenUsage: {
              total: { totalTokens: 700, inputTokens: 600, cachedInputTokens: 0, outputTokens: 100, reasoningOutputTokens: 0 },
              last: { totalTokens: 700, inputTokens: 600, cachedInputTokens: 0, outputTokens: 100, reasoningOutputTokens: 0 },
              modelContextWindow: 128_000,
            },
          })
          notify('item/completed', {
            threadId: message.params.threadId, turnId,
            item: {
              type: 'subAgentActivity', id: 'child-activity-start', kind: 'started',
              agentThreadId: childThreadId, agentPath: '/root/metrics_child',
            },
          })
          notify('item/completed', {
            threadId: message.params.threadId, turnId,
            item: {
              type: 'subAgentActivity', id: 'zero-tool-activity-start', kind: 'started',
              agentThreadId: 'thread-child-zero-tools', agentPath: '/root/zero_tool_child',
            },
          })
          notify('thread/tokenUsage/updated', {
            threadId: 'thread-child-zero-tools', turnId: 'codex-child-turn-2',
            tokenUsage: {
              total: { totalTokens: 250, inputTokens: 200, cachedInputTokens: 0, outputTokens: 50, reasoningOutputTokens: 0 },
              last: { totalTokens: 250, inputTokens: 200, cachedInputTokens: 0, outputTokens: 50, reasoningOutputTokens: 0 },
              modelContextWindow: 128_000,
            },
          })
          notify('item/completed', {
            threadId: message.params.threadId, turnId,
            item: {
              type: 'subAgentActivity', id: 'zero-tool-activity-done', kind: 'completed',
              agentThreadId: 'thread-child-zero-tools', agentPath: '/root/zero_tool_child',
            },
          })
          notify('item/started', {
            threadId: childThreadId, turnId: childTurnId,
            item: {
              type: 'commandExecution', id: 'child-command-1', command: 'git status',
              cwd: message.params.cwd, status: 'inProgress',
            },
          })
          notify('item/completed', {
            threadId: childThreadId, turnId: childTurnId,
            item: {
              type: 'commandExecution', id: 'child-command-1', command: 'git status',
              cwd: message.params.cwd, status: 'completed', exitCode: 0,
            },
          })
          notify('thread/tokenUsage/updated', {
            threadId: childThreadId, turnId: childTurnId,
            tokenUsage: {
              total: { totalTokens: 1_200, inputTokens: 1_000, cachedInputTokens: 0, outputTokens: 200, reasoningOutputTokens: 0 },
              last: { totalTokens: 300, inputTokens: 250, cachedInputTokens: 0, outputTokens: 50, reasoningOutputTokens: 0 },
              modelContextWindow: 128_000,
            },
          })
          notify('item/started', {
            threadId: childThreadId, turnId: childTurnId,
            item: { type: 'webSearch', id: 'child-search-1', query: 'Codex agent usage' },
          })
          notify('thread/tokenUsage/updated', {
            threadId: message.params.threadId, turnId,
            tokenUsage: {
              total: { totalTokens: 9_999, inputTokens: 8_000, cachedInputTokens: 1_000, outputTokens: 1_999, reasoningOutputTokens: 0 },
              last: { totalTokens: 432, inputTokens: 400, cachedInputTokens: 0, outputTokens: 32, reasoningOutputTokens: 0 },
              modelContextWindow: 128_000,
            },
          })
          notify('item/completed', {
            threadId: message.params.threadId, turnId,
            item: {
              type: 'subAgentActivity', id: 'child-activity-done', kind: 'completed',
              agentThreadId: childThreadId, agentPath: '/root/metrics_child',
            },
          })
          // Model metadata remains enrichable after the lifecycle terminal. The child row must
          // adopt the provider's effective reroute rather than inherit the parent turn's model.
          notify('model/rerouted', {
            threadId: childThreadId, turnId: childTurnId,
            fromModel: 'gpt-child-initial', toModel: 'gpt-child-rerouted',
            reason: 'highRiskCyberActivity',
          })
          // App Server may publish final usage after the child terminal boundary. It must
          // enrich the existing card without resurrecting it or losing the observed count.
          notify('thread/tokenUsage/updated', {
            threadId: childThreadId, turnId: childTurnId,
            tokenUsage: {
              total: { totalTokens: 1_500, inputTokens: 1_200, cachedInputTokens: 0, outputTokens: 300, reasoningOutputTokens: 0 },
              last: { totalTokens: 300, inputTokens: 200, cachedInputTokens: 0, outputTokens: 100, reasoningOutputTokens: 0 },
              modelContextWindow: 128_000,
            },
          })
          notify('item/completed', {
            threadId: childThreadId, turnId: childTurnId,
            item: { type: 'webSearch', id: 'child-search-1', query: 'Codex agent usage' },
          })
          notify('turn/completed', {
            threadId: message.params.threadId,
            turn: { id: turnId, status: 'completed', items: [], error: null },
          })
        } else if (['retry-success', 'mcp-status-no-inventory', 'mcp-status-zero-tools',
          'oauth-first-completes-second-holds', 'oauth-complete-two-servers',
          'oauth-complete-while-turn-active', 'oauth-retry-while-turn-active',
          'mcp-status-file'].includes(mode)) {
          if (['oauth-complete-while-turn-active', 'oauth-retry-while-turn-active'].includes(mode)
              && process.env.CODEX_FIXTURE_ACTIVE_AUTH_RELEASE_FILE
              && !fs.existsSync(process.env.CODEX_FIXTURE_ACTIVE_AUTH_RELEASE_FILE)) return
          if (process.env.CODEX_FIXTURE_REROUTE_FIRST_ROOT_TURN === '1'
              && startedTurns === 1) {
            notify('model/rerouted', {
              threadId: message.params.threadId, turnId,
              fromModel: 'gpt-thread-setting', toModel: 'gpt-first-turn-reroute',
              reason: 'fixtureReroute',
            })
          }
          notify('error', {
            threadId: message.params.threadId, turnId, willRetry: true,
            error: { message: 'Temporary disconnect.', codexErrorInfo: 'responseStreamDisconnected' },
          })
          notify('turn/completed', {
            threadId: message.params.threadId,
            turn: { id: turnId, status: 'completed', items: [], error: null },
          })
        } else if (mode === 'failed-merge') {
          notify('error', {
            threadId: message.params.threadId, turnId, willRetry: false,
            error: {
              message: 'Connection failed.',
              codexErrorInfo: { httpConnectionFailed: { httpStatusCode: 503 } },
            },
          })
          notify('turn/completed', {
            threadId: message.params.threadId,
            turn: {
              id: turnId, status: 'failed', items: [],
              error: { message: 'Authoritative final failure.', codexErrorInfo: null, additionalDetails: null },
            },
          })
        } else if (mode === 'retry-final-auth') {
          notify('error', {
            threadId: message.params.threadId, turnId, willRetry: true,
            error: {
              message: 'Temporary service failure.',
              codexErrorInfo: { httpConnectionFailed: { httpStatusCode: 503 } },
            },
          })
          notify('turn/completed', {
            threadId: message.params.threadId,
            turn: {
              id: turnId, status: 'failed', items: [],
              error: { message: 'Sign in again.', codexErrorInfo: 'unauthorized' },
            },
          })
        } else if (mode === 'sequential-late') {
          if (startedTurns === 1) {
            notify('turn/completed', {
              threadId: message.params.threadId,
              turn: { id: turnId, status: 'completed', items: [], error: null },
            })
          } else {
            send({
              id: 9201,
              method: 'item/commandExecution/requestApproval',
              params: {
                threadId: message.params.threadId, turnId: firstTurnId,
                itemId: 'late-a-command', command: 'echo stale', cwd: message.params.cwd,
              },
            })
            send({
              id: 9202,
              method: 'item/tool/call',
              params: {
                threadId: message.params.threadId, turn: { id: firstTurnId },
                callId: 'late-a-tool', tool: 'CreateOrUpdateArtifact',
                arguments: { type: 'markdown', title: 'Stale', source: 'must not run' },
              },
            })
            notify('item/agentMessage/delta', {
              threadId: message.params.threadId, turnId: firstTurnId,
              itemId: 'late-a-top-level', delta: 'LATE-A-TOP',
            })
            notify('item/agentMessage/delta', {
              threadId: message.params.threadId, turn: { id: firstTurnId },
              itemId: 'late-a-nested', delta: 'LATE-A-NESTED',
            })
            notify('item/agentMessage/delta', {
              threadId: message.params.threadId, turnId,
              itemId: 'current-b', delta: 'B',
            })
            notify('turn/completed', {
              threadId: message.params.threadId,
              turn: { id: turnId, status: 'completed', items: [], error: null },
            })
          }
        } else if (mode === 'exit-active') {
          send({
            id: 1000 + startedTurns,
            method: 'item/commandExecution/requestApproval',
            params: {
              threadId: message.params.threadId, turnId,
              itemId: 'command-' + startedTurns, command: 'echo fixture', cwd: message.params.cwd,
            },
          })
          if (startedTurns === 2) setTimeout(() => process.exit(17), 40)
        }
      }, 10)
      break
    }
    case 'turn/steer':
      if (process.env.CODEX_FIXTURE_STEER_FILE) {
        fs.writeFileSync(process.env.CODEX_FIXTURE_STEER_FILE, JSON.stringify(message.params))
      }
      send({ id: message.id, result: {} })
      notify('item/agentMessage/delta', {
        threadId: message.params.threadId,
        turnId: message.params.expectedTurnId,
        itemId: 'guided-response',
        delta: 'Guidance received.',
      })
      notify('turn/completed', {
        threadId: message.params.threadId,
        turn: { id: message.params.expectedTurnId, status: 'completed', items: [], error: null },
      })
      break
    case 'review/start': {
      if (process.env.CODEX_FIXTURE_REVIEW_FILE) {
        fs.writeFileSync(process.env.CODEX_FIXTURE_REVIEW_FILE, JSON.stringify(message.params))
      }
      reviewTurnId = 'codex-review-' + (++turnCounter)
      reviewThreadId = message.params.threadId
      const response = {
        id: message.id,
        result: {
          turn: { id: reviewTurnId, status: 'inProgress', items: [], error: null },
          reviewThreadId,
        },
      }
      const entered = {
        method: 'item/started',
        params: {
          threadId: reviewThreadId, turnId: reviewTurnId,
          item: { type: 'enteredReviewMode', id: 'review-mode', review: 'current changes' },
        },
      }
      // Emit the lifecycle start before the JSON-RPC response to exercise agentd's bounded early-event
      // ownership path. A healthy App Server may begin streaming as soon as the review turn exists.
      process.stdout.write(JSON.stringify(entered) + '\\n' + JSON.stringify(response) + '\\n')
      if (mode === 'review-workflow-forgery') {
        send({
          id: reviewWorkflowToolRequestId,
          method: 'item/tool/call',
          params: {
            threadId: reviewThreadId,
            turnId: reviewTurnId,
            callId: 'forged-review-workflow',
            tool: 'RecommendMechanicianWorkflow',
            arguments: {
              goal: 'Run a recipe from Review.',
              demonstrationID: 'mac.run-user-chosen-capability',
            },
          },
        })
        send({
          id: reviewShowToolRequestId,
          method: 'item/tool/call',
          params: {
            threadId: reviewThreadId,
            turnId: reviewTurnId,
            callId: 'forged-review-show',
            tool: 'ShowMechanician',
            arguments: { guideID: 'mechanician.artifacts-inspector' },
          },
        })
        break
      }
      if (mode === 'review-hold') break
      setTimeout(() => {
        const result = 'Looks solid overall.\\n\\n- Fix the edge case in app.js:10.'
        notify('item/started', {
          threadId: reviewThreadId, turnId: reviewTurnId,
          item: { type: 'exitedReviewMode', id: 'review-result', review: result },
        })
        notify('item/completed', {
          threadId: reviewThreadId, turnId: reviewTurnId,
          item: { type: 'exitedReviewMode', id: 'review-result', review: result },
        })
        // Inline review also sends an ordinary final assistant message containing the same text.
        // Mechanician must surface the authoritative review result once, not duplicate it as delta.
        notify('item/agentMessage/delta', {
          threadId: reviewThreadId, turnId: reviewTurnId,
          itemId: 'review-message', delta: result,
        })
        notify('item/completed', {
          threadId: reviewThreadId, turnId: reviewTurnId,
          item: { type: 'agentMessage', id: 'review-message', text: result },
        })
        notify('turn/completed', {
          threadId: reviewThreadId,
          turn: { id: reviewTurnId, status: 'completed', items: [], error: null },
        })
      }, 30)
      break
    }
    case 'turn/interrupt':
      if (mode === 'interrupt-no-active-terminal') {
        const turn = turnsById.get(message.params.turnId)
        if (turn) turn.status = 'interrupted'
        send({
          id: message.id,
          error: { code: -32001, message: 'no active turn to interrupt' },
        })
        break
      }
      send({ id: message.id, result: {} })
      if (mode === 'interrupt-approval' || mode === 'residency-hold'
          || mode === 'oauth-complete-while-turn-active'
          || mode === 'oauth-retry-while-turn-active') {
        if (['oauth-complete-while-turn-active', 'oauth-retry-while-turn-active'].includes(mode)
            && process.env.CODEX_FIXTURE_ACTIVE_AUTH_RELEASE_FILE) {
          fs.writeFileSync(process.env.CODEX_FIXTURE_ACTIVE_AUTH_RELEASE_FILE, 'released')
        }
        const turn = turnsById.get(message.params.turnId)
        if (turn) turn.status = 'interrupted'
        notify('turn/completed', {
          threadId: turn?.threadId,
          turn: {
            id: message.params.turnId, status: 'interrupted', items: [], error: null,
          },
        })
      }
      if (mode === 'review-hold' && message.params.turnId === reviewTurnId) {
        notify('turn/completed', {
          threadId: reviewThreadId,
          turn: { id: reviewTurnId, status: 'interrupted', items: [], error: null },
        })
      }
      break
    default:
      send({ id: message.id, result: {} })
  }
})
`

async function waitFor(predicate, description, fixture, timeout = 5000) {
  const deadline = Date.now() + timeout
  while (Date.now() < deadline) {
    const value = predicate()
    if (value) return value
    await delay(10)
  }
  assert.fail(`timed out waiting for ${description}\nagentd stderr:\n${fixture.stderr}`)
}

function send(child, request) {
  child.stdin.write(`${JSON.stringify(request)}\n`)
}

async function startAgentd(t, mode, environment = {}) {
  const config = fs.mkdtempSync(path.join(os.tmpdir(), 'mechanician-codex-errors-'))
  const executable = path.join(config, 'codex-fixture.mjs')
  fs.writeFileSync(executable, fakeCodexSource, { mode: 0o700 })
  const child = spawn(process.execPath, [agentd], {
    env: {
      ...process.env,
      MECHANICIAN_PROVIDER: 'codex',
      MECHANICIAN_CONFIG_DIR: config,
      MECHANICIAN_SUPPORT_DIR: config,
      MECHANICIAN_CWD: config,
      MECHANICIAN_CODEX_BIN: executable,
      MECHANICIAN_ACCOUNT_INSTANCE_ID: mcpAccountInstanceId,
      CODEX_FIXTURE_MODE: mode,
      OPENAI_API_KEY: '',
      ANTHROPIC_API_KEY: '',
      ...environment,
    },
    stdio: ['pipe', 'pipe', 'pipe'],
  })
  const events = []
  let buffered = ''
  let stderr = ''
  child.stdout.setEncoding('utf8')
  child.stderr.setEncoding('utf8')
  child.stdout.on('data', (chunk) => {
    buffered += chunk
    const lines = buffered.split('\n')
    buffered = lines.pop() ?? ''
    for (const line of lines) if (line) events.push(JSON.parse(line))
  })
  child.stderr.on('data', (chunk) => { stderr += chunk })
  const fixture = { child, config, events, get stderr() { return stderr } }
  t.after(() => {
    if (child.exitCode == null) child.kill()
    // The provider bootstrap is intentionally asynchronous and may finish one atomic config write
    // while SIGTERM is being delivered. Let recursive removal retry that narrow ENOTEMPTY race.
    fs.rmSync(config, { recursive: true, force: true, maxRetries: 20, retryDelay: 10 })
  })
  // Process startup is not the behavior under test. A shared CI runner spawning node plus the
  // Codex fixture can exceed the ordinary 5 s behavioral budget, which showed up as
  // "timed out waiting for reconcile-waits ready event" on an otherwise healthy run whose
  // stderr already contained the ready line. A longer budget delays a genuine hang; it never
  // passes one.
  await waitFor(
    () => events.find((event) => event.type === 'ready'),
    `${mode} ready event`, fixture, 30000,
  )
  return fixture
}

test('Codex App Server receives only its isolated subscription environment', async (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'mechanician-codex-env-'))
  const capture = path.join(root, 'environment.json')
  t.after(() => fs.rmSync(root, { recursive: true, force: true }))
  await startAgentd(t, 'signed-out', {
    CODEX_FIXTURE_ENV_FILE: capture,
    OPENAI_API_KEY: 'must-not-reach-codex',
    ANTHROPIC_API_KEY: 'must-not-reach-codex',
    ANTHROPIC_AUTH_TOKEN: 'must-not-reach-codex',
    CLAUDE_CODE_OAUTH_TOKEN: 'must-not-reach-codex',
    CLAUDE_CODE_API_KEY_FILE_DESCRIPTOR: '8',
    CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR: '9',
  })
  const observed = JSON.parse(await fs.promises.readFile(capture, 'utf8'))
  assert.deepEqual(observed, {
    openai: false,
    anthropic: false,
    anthropicAuth: false,
    claudeOAuth: false,
    apiDescriptor: false,
    oauthDescriptor: false,
    codexHome: observed.codexHome,
  })
  assert.match(observed.codexHome, /codex$/)
})

test('Codex emits an authoritative provider-neutral catalog automatically and on request', async (t) => {
  const fixture = await startAgentd(t, 'retry-success')
  const automatic = await waitFor(
    () => fixture.events.find((event) => event.type === 'model_catalog' && event.id === undefined),
    'automatic Codex model catalog', fixture,
  )
  assert.equal(automatic.scope, '')
  assert.equal(automatic.defaultModelID, 'gpt-fixture')
  assert.deepEqual(automatic.models, [{
    id: 'gpt-fixture', label: 'Fixture', isDefault: true,
    efforts: ['low', 'high'], capabilities: ['effort'],
  }])
  assert.equal(Object.hasOwn(automatic, 'provider'), false)

  send(fixture.child, {
    type: 'model_catalog', id: 'catalog-request', cwd: '/ignored', scope: 'ignored',
  })
  const requested = await waitFor(
    () => fixture.events.find((event) => event.type === 'model_catalog'
      && event.id === 'catalog-request'),
    'requested Codex model catalog', fixture,
  )
  assert.equal(requested.scope, '')
  assert.deepEqual(requested.models, automatic.models)
})

test('Codex emits successful empty catalog snapshots without disconnecting', async (t) => {
  const fixture = await startAgentd(t, 'catalog-empty')
  const catalog = await waitFor(
    () => fixture.events.find((event) => event.type === 'model_catalog'),
    'empty Codex catalog', fixture,
  )
  assert.deepEqual(catalog, { type: 'model_catalog', scope: '', models: [] })
  assert.equal(fixture.events.filter((event) => event.type === 'ready').at(-1).loggedIn, true)
})

test('Codex publishes App Server system, repository, and namespaced plugin skills', async (t) => {
  const fixture = await startAgentd(t, 'skills-authoritative')
  const catalog = await waitFor(
    () => fixture.events.find((event) => event.type === 'commands'
      && event.commands.some((command) => command.name === 'documents:documents')),
    'authoritative Codex skills', fixture,
  )

  assert.deepEqual(catalog.commands.map((command) => command.name), [
    'documents:documents',
    'repo-skill',
    'system-skill',
  ])
  assert.ok(catalog.commands.every((command) => command.invocationPrefix === '$'))
  assert.equal(catalog.commands.some((command) => command.name === 'disabled-skill'), false)
})

test('skills/changed invalidates and replaces the visible Codex inventory', async (t) => {
  const fixture = await startAgentd(t, 'skills-changed')
  await waitFor(
    () => fixture.events.find((event) => event.type === 'commands'
      && event.commands.some((command) => command.name === 'initial-skill')),
    'initial Codex skill catalog', fixture,
  )
  const updated = await waitFor(
    () => fixture.events.find((event) => event.type === 'commands'
      && event.commands.some((command) => command.name === 'updated-skill')),
    'updated Codex skill catalog', fixture,
  )

  assert.deepEqual(updated.commands.map((command) => command.name), ['updated-skill'])
})

test('an authoritative empty skills snapshot clears a removed catalog', async (t) => {
  const fixture = await startAgentd(t, 'skills-empty-refresh')
  const initialIndex = await waitFor(
    () => {
      const index = fixture.events.findIndex((event) => event.type === 'commands'
        && event.commands.some((command) => command.name === 'removed-skill'))
      return index >= 0 ? index : null
    },
    'non-empty Codex skill catalog', fixture,
  )
  const cleared = await waitFor(
    () => fixture.events.slice(initialIndex + 1).find((event) =>
      event.type === 'commands' && event.commands.length === 0),
    'empty Codex skill catalog', fixture,
  )

  assert.deepEqual(cleared.commands, [])
})

test('a failed skills refresh retains the last authoritative catalog', async (t) => {
  const fixture = await startAgentd(t, 'skills-failure-retain')
  const retainedIndex = await waitFor(
    () => {
      const index = fixture.events.findIndex((event) => event.type === 'commands'
        && event.commands.some((command) => command.name === 'retained-skill'))
      return index >= 0 ? index : null
    },
    'retained Codex skill catalog', fixture,
  )
  await waitFor(
    () => fixture.stderr.includes('skills/list failed; retaining the last catalog'),
    'failed skills refresh log', fixture,
  )
  await delay(100)

  assert.equal(
    fixture.events.slice(retainedIndex + 1).some((event) => event.type === 'commands'),
    false,
  )
})

test('an older valid same-workspace result survives a newer overlapping refresh failure', async (t) => {
  const fixture = await startAgentd(t, 'skills-overlap-failure')
  await waitFor(
    () => fixture.stderr.includes('newer overlapping skills request failed'),
    'newer overlapping skill failure', fixture,
  )
  const catalog = await waitFor(
    () => fixture.events.find((event) => event.type === 'commands'
      && event.commands.some((command) => command.name === 'overlap-valid')),
    'older valid skill result', fixture,
  )

  assert.deepEqual(catalog.commands.map((command) => command.name), ['overlap-valid'])
})

test('skill inventory maintenance does not start another refresh during an active turn', async (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'mechanician-skills-active-turn-'))
  const calls = path.join(root, 'skills.ndjson')
  t.after(() => fs.rmSync(root, { recursive: true, force: true }))
  const fixture = await startAgentd(t, 'skills-turn-active', {
    CODEX_FIXTURE_SKILLS_LOG_FILE: calls,
  })
  await waitFor(
    () => fs.existsSync(calls) && fs.readFileSync(calls, 'utf8').trim().length > 0,
    'idle startup skills request', fixture,
  )
  const before = fs.readFileSync(calls, 'utf8').trim().split('\n').length

  send(fixture.child, {
    type: 'send',
    id: 'skills-active-turn',
    convId: 'conv-skills-active-turn',
    prompt: 'keep the provider turn active',
    model: 'gpt-fixture',
  })
  await waitFor(
    () => fixture.events.find((event) =>
      event.id === 'skills-active-turn' && event.type === 'status'
        && event.status === 'thinking'),
    'active provider turn', fixture,
  )
  await delay(1_300)

  const after = fs.readFileSync(calls, 'utf8').trim().split('\n').length
  assert.equal(after, before)
})

test('a slow prior-workspace skills response cannot overwrite the new workspace', async (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'mechanician-skills-cwd-'))
  const calls = path.join(root, 'skills.ndjson')
  const next = path.join(root, 'next')
  fs.mkdirSync(next)
  t.after(() => fs.rmSync(root, { recursive: true, force: true }))
  const fixture = await startAgentd(t, 'skills-cwd-race', {
    CODEX_FIXTURE_SKILLS_LOG_FILE: calls,
  })
  await waitFor(
    () => fs.existsSync(calls) && fs.readFileSync(calls, 'utf8').trim().length > 0,
    'old-workspace skills request', fixture,
  )

  send(fixture.child, { type: 'set_cwd', id: 'skills-next', path: next })
  const nextIndex = await waitFor(
    () => {
      const index = fixture.events.findIndex((event) => event.type === 'commands'
        && event.commands.some((command) => command.name === 'from-next'))
      return index >= 0 ? index : null
    },
    'new-workspace Codex skills', fixture,
  )
  await delay(250)

  assert.equal(
    fixture.events.slice(nextIndex + 1).some((event) => event.type === 'commands'
      && event.commands.some((command) => command.name === 'from-old')),
    false,
  )
})

test('a failed new-workspace refresh immediately removes the prior repository skills', async (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'mechanician-skills-failed-cwd-'))
  const next = path.join(root, 'next')
  fs.mkdirSync(next)
  t.after(() => fs.rmSync(root, { recursive: true, force: true }))
  const fixture = await startAgentd(t, 'skills-cwd-failure')
  const oldIndex = await waitFor(
    () => {
      const index = fixture.events.findIndex((event) => event.type === 'commands'
        && event.commands.some((command) => command.name === 'from-old-before-failure'))
      return index >= 0 ? index : null
    },
    'old-workspace skills', fixture,
  )

  send(fixture.child, { type: 'set_cwd', id: 'failed-skills-next', path: next })
  const reset = await waitFor(
    () => fixture.events.slice(oldIndex + 1).find((event) =>
      event.type === 'commands' && event.commands.length === 0),
    'new-workspace safe fallback', fixture,
  )
  await waitFor(
    () => fixture.stderr.includes('new workspace skills failed'),
    'new-workspace skill failure', fixture,
  )

  assert.deepEqual(reset.commands, [])
  assert.equal(
    fixture.events.slice(oldIndex + 1).some((event) => event.type === 'commands'
      && event.commands.some((command) => command.name === 'from-old-before-failure')),
    false,
  )
})

test('loading a folder-less conversation refreshes skills for Home, not the prior project', async (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'mechanician-skills-home-'))
  const calls = path.join(root, 'skills.ndjson')
  t.after(() => fs.rmSync(root, { recursive: true, force: true }))
  const fixture = await startAgentd(t, 'skills-folderless', {
    CODEX_FIXTURE_SKILLS_LOG_FILE: calls,
  })
  const projectIndex = await waitFor(
    () => {
      const index = fixture.events.findIndex((event) => event.type === 'commands'
        && event.commands.some((command) => command.name === 'project-before-home'))
      return index >= 0 ? index : null
    },
    'project skills before folder-less load', fixture,
  )

  send(fixture.child, {
    type: 'load', id: 'folderless-load', cwd: '', sessionId: null,
  })
  const home = await waitFor(
    () => fixture.events.slice(projectIndex + 1).find((event) =>
      event.type === 'commands'
        && event.commands.some((command) => command.name === 'home-skill')),
    'Home skill inventory', fixture,
  )
  const requests = fs.readFileSync(calls, 'utf8').trim().split('\n').map(JSON.parse)

  assert.deepEqual(home.commands.map((command) => command.name), ['home-skill'])
  assert.deepEqual(requests.at(-1).cwds, [os.homedir()])
})

test('Codex catalog failure is terminal for discovery but preserves the connected runtime', async (t) => {
  const fixture = await startAgentd(t, 'catalog-error')
  const failure = await waitFor(
    () => fixture.events.find((event) => event.type === 'model_catalog_error'),
    'Codex catalog error', fixture,
  )
  assert.equal(failure.scope, '')
  assert.match(failure.message, /fixture catalog failed/i)
  assert.equal(fixture.events.filter((event) => event.type === 'ready').at(-1).loggedIn, true)
})

async function runTurn(
  fixture,
  id = 'turn-1',
  overrides = {},
  terminalTypes = ['error', 'done'],
) {
  send(fixture.child, {
    type: 'send', id, convId: `conv-${id}`, prompt: 'fixture prompt', model: 'gpt-fixture',
    ...overrides,
  })
  return await waitFor(
    () => fixture.events.find((event) => event.id === id
      && terminalTypes.includes(event.type)),
    `${id} terminal event`, fixture,
  )
}

test('Codex imageGeneration completion emits one durable transcript image handoff', async (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'mechanician-generated-image-'))
  const sourcePath = path.join(root, 'source.png')
  let handoffPath = null
  const source = Buffer.from(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScL0NwAAAABJRU5ErkJggg==',
    'base64',
  )
  fs.writeFileSync(sourcePath, source)
  t.after(() => fs.rmSync(root, { recursive: true, force: true }))
  t.after(() => {
    if (handoffPath) fs.rmSync(handoffPath, { force: true })
  })

  const fixture = await startAgentd(t, 'image-generation', {
    CODEX_FIXTURE_IMAGE_PATH: sourcePath,
  })
  const terminal = await runTurn(fixture, 'image-generation-turn')
  assert.deepEqual(terminal, { type: 'done', id: 'image-generation-turn' })

  const uses = fixture.events.filter((event) => event.id === 'image-generation-turn'
    && event.type === 'tool_use' && event.toolUseId === 'generated-image-1')
  const results = fixture.events.filter((event) => event.id === 'image-generation-turn'
    && event.type === 'tool_result' && event.toolUseId === 'generated-image-1')
  assert.deepEqual(uses, [{
    type: 'tool_use', id: 'image-generation-turn', toolUseId: 'generated-image-1',
    name: 'ImageGeneration', input: { prompt: 'watercolor fox' },
  }])
  assert.equal(results.length, 1, 'a replayed terminal item must not duplicate transcript media')
  const result = results[0]
  assert.equal(result.status, 'success')
  assert.equal(result.result, 'Generated image.')
  assert.equal(result.generatedImageBytes, source.length)
  assert.equal(typeof result.generatedImagePath, 'string')
  handoffPath = result.generatedImagePath
  assert.notEqual(handoffPath, sourcePath, 'provider temporary paths never cross the protocol')
  assert.match(
    path.basename(handoffPath),
    /^mechanician-generated-image-[0-9a-f-]+\.image$/i,
  )
  assert.deepEqual(fs.readFileSync(handoffPath), source)
  fs.rmSync(handoffPath, { force: true })
  handoffPath = null
  assertOneTerminal(fixture, 'image-generation-turn')
})

test('Codex reports the effective root model from thread start and resume', async (t) => {
  const fixture = await startAgentd(t, 'retry-success', {
    CODEX_FIXTURE_START_MODEL: 'gpt-provider-start',
    CODEX_FIXTURE_RESUME_MODEL: 'gpt-provider-resume',
  })

  assert.deepEqual(await runTurn(fixture, 'fresh-model-turn'), {
    type: 'done',
    id: 'fresh-model-turn',
  })
  assert.deepEqual(
    fixture.events.filter((event) =>
      event.id === 'fresh-model-turn' && event.type === 'agent_model'),
    [{
      type: 'agent_model',
      id: 'fresh-model-turn',
      agentId: 'root',
      model: 'gpt-provider-start',
      modelProvider: 'openai',
    }],
  )

  assert.deepEqual(await runTurn(fixture, 'resumed-model-turn', {
    sessionId: 'codex-tools:provider-owned-thread',
  }), {
    type: 'done',
    id: 'resumed-model-turn',
  })
  assert.deepEqual(
    fixture.events.filter((event) =>
      event.id === 'resumed-model-turn' && event.type === 'agent_model'),
    [{
      type: 'agent_model',
      id: 'resumed-model-turn',
      agentId: 'root',
      model: 'gpt-provider-resume',
      modelProvider: 'openai',
    }],
  )
})

test('Codex configures workspace instructions on a fresh thread without rewriting user input', async (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'mechanician-codex-instructions-'))
  const starts = path.join(root, 'starts.ndjson')
  const turns = path.join(root, 'turns.ndjson')
  t.after(() => fs.rmSync(root, { recursive: true, force: true }))
  const fixture = await startAgentd(t, 'retry-success', {
    CODEX_FIXTURE_THREAD_START_LOG_FILE: starts,
    CODEX_FIXTURE_TURN_FILE: turns,
  })

  const terminal = await runTurn(fixture, 'instruction-start', {
    cwd: root,
    prompt: 'Keep this user message exact.',
    projectInstructions: 'Prefer the smallest correct change.',
    workspaceInstructionsRevision: 'workspace-revision-1',
    allowRepositoryInstructions: false,
  })
  assert.deepEqual(terminal, { type: 'done', id: 'instruction-start' })

  const start = fs.readFileSync(starts, 'utf8').trim().split('\n').map(JSON.parse).at(-1)
  assertDeveloperInstructions(start.developerInstructions, 'Prefer the smallest correct change.')
  assertNoTransientMcpConfig(start.config, { project_doc_max_bytes: 0 })
  assert.equal(start.cwd, root)
  assert.equal('excludeTurns' in start, false)
  assert.ok(Array.isArray(start.dynamicTools))

  const turn = fs.readFileSync(turns, 'utf8').trim().split('\n').map(JSON.parse).at(-1)
  assert.deepEqual(turn.input, [{ type: 'text', text: 'Keep this user message exact.' }])
  assert.doesNotMatch(turn.input[0].text, /Project instructions/i)
  assert.doesNotMatch(turn.input[0].text, /smallest correct change/i)
})

test('Codex preloads the selected thread and consumes that exact warm state on send', async (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'mechanician-codex-prewarm-'))
  const resumes = path.join(root, 'resumes.ndjson')
  t.after(() => fs.rmSync(root, { recursive: true, force: true }))
  const fixture = await startAgentd(t, 'retry-success', {
    CODEX_FIXTURE_RESUME_LOG_FILE: resumes,
  })

  send(fixture.child, {
    type: 'prewarm', id: 'prewarm-1',
    sessionId: 'codex-tools:selected-thread',
    model: 'gpt-fixture',
    cwd: root,
    permissionMode: 'default',
    projectInstructions: 'Keep APIs backwards compatible.',
    workspaceInstructionsRevision: 'workspace-revision-stable',
    allowRepositoryInstructions: false,
  })
  await waitFor(
    () => fixture.stderr.includes('phase=thread_prewarm_ready'),
    'Codex selected-thread prewarm', fixture,
  )

  const terminal = await runTurn(fixture, 'prewarmed-turn', {
    sessionId: 'codex-tools:selected-thread',
    model: 'gpt-fixture',
    cwd: root,
    permissionMode: 'default',
    projectInstructions: 'Keep APIs backwards compatible.',
    workspaceInstructionsRevision: 'workspace-revision-stable',
    allowRepositoryInstructions: false,
  })
  await delay(20)

  assert.deepEqual(terminal, { type: 'done', id: 'prewarmed-turn' })
  const requests = fs.readFileSync(resumes, 'utf8')
    .trim().split('\n').map((line) => JSON.parse(line))
  assert.equal(requests.length, 1, 'send must reuse the confirmed exact-config prewarm')
  assert.equal(requests[0].threadId, 'selected-thread')
  assert.equal(requests[0].excludeTurns, true)
  assert.equal(requests[0].model, 'gpt-fixture')
  assert.equal(requests[0].cwd, root)
  assert.equal(requests[0].approvalPolicy, 'untrusted')
  assert.equal(requests[0].approvalsReviewer, 'user')
  assert.equal(requests[0].sandbox, 'workspace-write')
  assertDeveloperInstructions(requests[0].developerInstructions, 'Keep APIs backwards compatible.')
  assertNoTransientMcpConfig(requests[0].config, { project_doc_max_bytes: 0 })
  assert.equal('dynamicTools' in requests[0], false)
  assert.deepEqual(fixture.events.filter((event) =>
    event.id === 'prewarmed-turn' && event.type === 'agent_model'), [{
    type: 'agent_model', id: 'prewarmed-turn', agentId: 'root',
    model: 'gpt-fixture', modelProvider: 'openai',
  }])
  const stages = fixture.events
    .filter((event) => event.type === 'status' && event.id === 'prewarmed-turn')
    .map((event) => event.status)
  assert.ok(stages.includes('resuming_thread'))
  assert.ok(stages.includes('starting_codex'))
  assert.match(
    fixture.stderr,
    /turn=prewarmed-turn provider=codex phase=thread_ready .*warm=1/,
  )
})

test('a changed workspace-instruction revision replaces the Codex thread and replays durable history', async (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'mechanician-codex-instruction-revision-'))
  const starts = path.join(root, 'starts.ndjson')
  const resumes = path.join(root, 'resumes.ndjson')
  const turns = path.join(root, 'turns.ndjson')
  t.after(() => fs.rmSync(root, { recursive: true, force: true }))
  const fixture = await startAgentd(t, 'retry-success', {
    CODEX_FIXTURE_THREAD_START_LOG_FILE: starts,
    CODEX_FIXTURE_RESUME_LOG_FILE: resumes,
    CODEX_FIXTURE_TURN_FILE: turns,
  })

  assert.deepEqual(await runTurn(fixture, 'old-instruction-turn', {
    sessionId: 'codex-tools:existing-instruction-thread',
    cwd: root,
    prompt: 'old question',
    projectInstructions: 'Use the old convention.',
    workspaceInstructionsRevision: 'workspace-revision-old',
    allowRepositoryInstructions: true,
  }), { type: 'done', id: 'old-instruction-turn' })

  assert.deepEqual(await runTurn(fixture, 'new-instruction-turn', {
    sessionId: 'codex-tools:existing-instruction-thread',
    cwd: root,
    prompt: 'new question',
    history: [
      { role: 'user', text: 'old question' },
      { role: 'assistant', text: 'old answer' },
      { role: 'user', text: 'new question' },
    ],
    projectInstructions: 'Use the new convention.',
    workspaceInstructionsRevision: 'workspace-revision-new',
    allowRepositoryInstructions: true,
  }), { type: 'done', id: 'new-instruction-turn' })

  const resumeRequests = fs.readFileSync(resumes, 'utf8')
    .trim().split('\n').map(JSON.parse)
  assert.equal(resumeRequests.length, 1, 'the stale provider thread must not be resumed again')
  assertDeveloperInstructions(resumeRequests[0].developerInstructions, 'Use the old convention.')

  const startRequests = fs.readFileSync(starts, 'utf8')
    .trim().split('\n').map(JSON.parse)
  assert.equal(startRequests.length, 1)
  assertDeveloperInstructions(startRequests[0].developerInstructions, 'Use the new convention.')
  assertNoTransientMcpConfig(startRequests[0].config)

  const turnRequests = fs.readFileSync(turns, 'utf8')
    .trim().split('\n').map(JSON.parse)
  assert.equal(turnRequests.length, 2)
  assert.equal(turnRequests[1].threadId, 'thread-1')
  assert.match(turnRequests[1].input[0].text, /User: old question/)
  assert.match(turnRequests[1].input[0].text, /Assistant: old answer/)
  assert.match(turnRequests[1].input[0].text, /The user now says:\n\nnew question/)
  assert.doesNotMatch(turnRequests[1].input[0].text, /Use the new convention/)
  assert.ok(fixture.events.some((event) =>
    event.type === 'session'
      && event.id === 'new-instruction-turn'
      && /^codex-tools:thread-1:mechanician-mcp:[a-f0-9]{64}:mechanician-profile:standard$/
        .test(event.sessionId)))
})

test('a model change invalidates an older prewarm proof before publishing root identity', async (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'mechanician-codex-model-prewarm-'))
  const resumes = path.join(root, 'resumes.ndjson')
  t.after(() => fs.rmSync(root, { recursive: true, force: true }))
  const fixture = await startAgentd(t, 'retry-success', {
    CODEX_FIXTURE_RESUME_LOG_FILE: resumes,
  })

  send(fixture.child, {
    type: 'prewarm', id: 'prewarm-old-model',
    sessionId: 'codex-tools:model-switch-thread',
    model: 'gpt-old-model',
    cwd: root,
    permissionMode: 'default',
  })
  await waitFor(
    () => fixture.stderr.includes('phase=thread_prewarm_ready'),
    'old-model prewarm', fixture,
  )

  const terminal = await runTurn(fixture, 'model-switch-turn', {
    sessionId: 'codex-tools:model-switch-thread',
    model: 'gpt-new-model',
    cwd: root,
    permissionMode: 'default',
  })
  assert.deepEqual(terminal, { type: 'done', id: 'model-switch-turn' })
  const requests = fs.readFileSync(resumes, 'utf8')
    .trim().split('\n').map((line) => JSON.parse(line))
  assert.deepEqual(requests.map((request) => request.model), [
    'gpt-old-model',
    'gpt-new-model',
  ])
  assert.deepEqual(fixture.events.filter((event) =>
    event.id === 'model-switch-turn' && event.type === 'agent_model'), [{
    type: 'agent_model', id: 'model-switch-turn', agentId: 'root',
    model: 'gpt-new-model', modelProvider: 'openai',
  }])
})

test('a settings notification before resume response remains authoritative for the root', async (t) => {
  const fixture = await startAgentd(t, 'retry-success', {
    CODEX_FIXTURE_REORDER_RESUME_MODEL: '1',
  })
  const terminal = await runTurn(fixture, 'reordered-root-model', {
    sessionId: 'codex-tools:reordered-root-thread',
    model: 'gpt-requested',
  })

  assert.deepEqual(terminal, { type: 'done', id: 'reordered-root-model' })
  assert.deepEqual(fixture.events.filter((event) =>
    event.id === 'reordered-root-model' && event.type === 'agent_model'), [{
    type: 'agent_model', id: 'reordered-root-model', agentId: 'root',
    model: 'gpt-notification-newer', modelProvider: 'openai',
  }])
  assert.equal(fixture.events.some((event) =>
    event.id === 'reordered-root-model'
      && event.type === 'workflow_update'
      && event.taskId === 'reordered-root-thread'), false)
})

test('an exact-warm turn never inherits the prior turn model reroute', async (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'mechanician-codex-reroute-warm-'))
  const resumes = path.join(root, 'resumes.ndjson')
  t.after(() => fs.rmSync(root, { recursive: true, force: true }))
  const fixture = await startAgentd(t, 'retry-success', {
    CODEX_FIXTURE_RESUME_LOG_FILE: resumes,
    CODEX_FIXTURE_RESUME_MODEL: 'gpt-thread-setting',
    CODEX_FIXTURE_REROUTE_FIRST_ROOT_TURN: '1',
  })
  const sessionId = 'codex-tools:rerouted-warm-thread'

  assert.deepEqual(await runTurn(fixture, 'rerouted-first-turn', {
    sessionId,
  }), {
    type: 'done',
    id: 'rerouted-first-turn',
  })
  assert.deepEqual(fixture.events.filter((event) =>
    event.id === 'rerouted-first-turn' && event.type === 'agent_model').map((event) =>
    event.model), [
    'gpt-thread-setting',
    'gpt-first-turn-reroute',
  ])

  assert.deepEqual(await runTurn(fixture, 'warm-after-reroute', {
    sessionId,
  }), {
    type: 'done',
    id: 'warm-after-reroute',
  })
  assert.deepEqual(fixture.events.filter((event) =>
    event.id === 'warm-after-reroute' && event.type === 'agent_model').map((event) =>
    event.model), [
    'gpt-thread-setting',
  ])
  const requests = fs.readFileSync(resumes, 'utf8')
    .trim().split('\n').map((line) => JSON.parse(line))
  assert.equal(requests.length, 1, 'the second turn must consume the exact warm proof')
})

test('Codex replays durable history only when starting a replacement thread', async (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'mechanician-codex-history-'))
  const capture = path.join(root, 'turns.ndjson')
  t.after(() => fs.rmSync(root, { recursive: true, force: true }))
  const fixture = await startAgentd(t, 'retry-success', {
    CODEX_FIXTURE_TURN_FILE: capture,
  })
  const history = [
    { role: 'user', text: 'first question' },
    { role: 'assistant', text: 'first answer' },
    { role: 'user', text: 'follow up' },
  ]

  await runTurn(fixture, 'resumed-turn', {
    prompt: 'follow up', sessionId: 'codex-tools:existing-thread',
    history, replayHistory: true,
  })
  await runTurn(fixture, 'replacement-turn', {
    prompt: 'follow up', sessionId: null,
    history, replayHistory: true,
  })

  const turns = fs.readFileSync(capture, 'utf8')
    .trim().split('\n').map((line) => JSON.parse(line))
  assert.equal(turns[0].threadId, 'existing-thread')
  assert.equal(turns[0].input[0].text, 'follow up')
  assert.equal(turns[1].threadId, 'thread-1')
  assert.match(turns[1].input[0].text, /^Here is our earlier conversation, for context:/)
  assert.match(turns[1].input[0].text, /User: first question/)
  assert.match(turns[1].input[0].text, /Assistant: first answer/)
  assert.match(turns[1].input[0].text, /Continue naturally\. The user now says:\n\nfollow up$/)
})

function assertOneTerminal(fixture, id) {
  assert.equal(
    fixture.events.filter((event) => event.id === id
      && (event.type === 'error' || event.type === 'done')).length,
    1,
  )
}

test('Codex diagnostics export only the bounded privacy-safe lifecycle snapshot', async (t) => {
  const fixture = await startAgentd(t, 'retry-success')
  await runTurn(fixture, 'diagnostic-turn', {
    prompt: 'PRIVATE_DIAGNOSTIC_PROMPT_MUST_NOT_LEAVE_AGENTD',
    effort: 'ultra',
  })
  send(fixture.child, { type: 'codex_diagnostics', id: 'diagnostics-1' })
  const response = await waitFor(
    () => fixture.events.find((event) =>
      event.type === 'codex_diagnostics' && event.id === 'diagnostics-1'),
    'Codex diagnostics export', fixture,
  )

  assert.equal(response.diagnostics.format, 'ai.mechanician.codex-lifecycle.v1')
  assert.ok(response.diagnostics.entryCount > 0)
  assert.ok(response.diagnostics.entryCount <= response.diagnostics.maximumEntryCount)
  assert.equal(response.diagnostics.redaction.prompts, 'excluded')
  assert.ok(response.diagnostics.entries.some((entry) => entry.effort === 'ultra'))
  assert.doesNotMatch(
    JSON.stringify(response.diagnostics),
    /PRIVATE_DIAGNOSTIC_PROMPT_MUST_NOT_LEAVE_AGENTD/,
  )
})

test('persisted MCP readiness blocks Codex Review before a provider thread starts', async (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'mechanician-codex-review-mcp-gate-'))
  const support = path.join(root, 'support')
  const starts = path.join(root, 'thread-starts.ndjson')
  writePendingCodexMcpSidecar(support)
  t.after(() => fs.rmSync(root, { recursive: true, force: true }))
  const fixture = await startAgentd(t, 'review-success', {
    MECHANICIAN_SUPPORT_DIR: support,
    CODEX_FIXTURE_THREAD_START_LOG_FILE: starts,
  })

  send(fixture.child, {
    type: 'review_start', id: 'review-pending-mcp', convId: 'conv-review-pending-mcp',
    cwd: root, model: 'gpt-fixture', target: { type: 'uncommittedChanges' },
  })
  const rejected = await waitFor(
    () => fixture.events.find((event) => event.type === 'control_error'
      && event.id === 'review-pending-mcp'),
    'persisted MCP Review rejection', fixture,
  )

  assert.match(rejected.message, /finish activating.*MCP connection/i)
  assert.equal(fixture.events.some((event) => event.type === 'turn_started'
    && event.id === 'review-pending-mcp'), false)
  assert.equal(fs.existsSync(starts), false)
})

test('persisted MCP authorization blocks Codex prewarm without resuming a thread', async (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'mechanician-codex-prewarm-mcp-gate-'))
  const support = path.join(root, 'support')
  const resumes = path.join(root, 'resumes.ndjson')
  writePendingCodexMcpSidecar(support, { authorization: true })
  t.after(() => fs.rmSync(root, { recursive: true, force: true }))
  const fixture = await startAgentd(t, 'retry-success', {
    MECHANICIAN_SUPPORT_DIR: support,
    CODEX_FIXTURE_RESUME_LOG_FILE: resumes,
  })

  send(fixture.child, {
    type: 'prewarm', id: 'prewarm-pending-mcp',
    sessionId: 'codex-tools:pre-auth-thread', model: 'gpt-fixture', cwd: root,
    permissionMode: 'default', projectInstructions: '',
  })
  await delay(200)

  assert.equal(fs.existsSync(resumes), false)
  assert.match(fixture.stderr, /prewarm skipped reason=mcp_credential_boundary/)
})

test('Codex native Review isolates a persisted conversation onto an exact reduced-surface thread', async (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'mechanician-codex-review-'))
  const capture = path.join(root, 'review.json')
  const starts = path.join(root, 'starts.ndjson')
  const resumeCapture = path.join(root, 'resume.json')
  t.after(() => fs.rmSync(root, { recursive: true, force: true }))
  const fixture = await startAgentd(t, 'review-success', {
    CODEX_FIXTURE_REVIEW_FILE: capture,
    CODEX_FIXTURE_THREAD_START_LOG_FILE: starts,
    CODEX_FIXTURE_RESUME_FILE: resumeCapture,
  })
  const id = 'review-1'
  send(fixture.child, {
    type: 'review_start', id, convId: 'conv-review',
    sessionId: 'codex-tools:existing-review-thread', cwd: root,
    model: 'gpt-fixture', permissionMode: 'default',
    projectInstructions: 'Flag correctness risks before style concerns.',
    workspaceInstructionsRevision: 'review-workspace-revision',
    allowRepositoryInstructions: false,
    target: { type: 'uncommittedChanges', ignored: 'must-not-cross-wire' },
  })

  const terminal = await waitFor(
    () => fixture.events.find((event) => event.id === id
      && (event.type === 'done' || event.type === 'error')),
    'review terminal', fixture,
  )
  const started = fixture.events.filter((event) => event.id === id && event.type === 'review_started')
  const results = fixture.events.filter((event) => event.id === id && event.type === 'review_result')
  const request = JSON.parse(fs.readFileSync(capture, 'utf8'))
  const startedThread = fs.readFileSync(starts, 'utf8').trim().split('\n').map(JSON.parse).at(-1)

  assert.deepEqual(request, {
    threadId: 'thread-1',
    target: { type: 'uncommittedChanges' },
    delivery: 'inline',
  })
  assert.equal(fs.existsSync(resumeCapture), false,
    'Review must not resume a thread whose immutable standard surface includes workflow advice')
  assert.equal(startedThread.cwd, root)
  assert.equal(startedThread.model, 'gpt-fixture')
  assert.equal(startedThread.approvalPolicy, 'on-request')
  assert.equal(startedThread.approvalsReviewer, 'user')
  assert.equal(startedThread.sandbox, 'read-only')
  assertDeveloperInstructions(
    startedThread.developerInstructions,
    'Flag correctness risks before style concerns.',
    { workflowAdviceEnabled: false },
  )
  assertNoTransientMcpConfig(startedThread.config, { project_doc_max_bytes: 0 })
  assert.equal(startedThread.dynamicTools.some(
    (tool) => tool.name === 'RecommendMechanicianWorkflow'), false)
  assert.deepEqual(started, [{
    type: 'review_started', id,
    reviewId: 'codex-review-1', target: 'uncommittedChanges',
    delivery: 'inline', label: 'current changes',
  }])
  assert.deepEqual(results, [{
    type: 'review_result', id,
    reviewId: 'codex-review-1', target: 'uncommittedChanges', delivery: 'inline',
    text: 'Looks solid overall.\n\n- Fix the edge case in app.js:10.',
  }])
  assert.deepEqual(fixture.events.filter((event) =>
    event.id === id && event.type === 'agent_model'), [{
    type: 'agent_model', id, agentId: 'root',
    model: 'gpt-fixture', modelProvider: 'openai',
  }])
  assert.deepEqual(terminal, { type: 'done', id })
  assert.equal(fixture.events.filter((event) => event.id === id && event.type === 'delta').length, 0)
  assert.equal(fixture.events.filter(
    (event) => event.id === id && event.type === 'tool_surface').length, 0)
  assert.equal(fixture.events.filter((event) => event.id === id && event.type === 'turn_started').length, 1)
  assert.ok(fixture.events.findIndex((event) => event.id === id && event.type === 'turn_started')
    < fixture.events.findIndex((event) => event.id === id && event.type === 'review_started'))
  assertOneTerminal(fixture, id)
})

test('a fresh Codex Review thread receives workspace instructions and folderless discovery policy', async (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'mechanician-codex-fresh-review-'))
  const starts = path.join(root, 'starts.ndjson')
  const reviewCapture = path.join(root, 'review.json')
  t.after(() => fs.rmSync(root, { recursive: true, force: true }))
  const fixture = await startAgentd(t, 'review-success', {
    CODEX_FIXTURE_THREAD_START_LOG_FILE: starts,
    CODEX_FIXTURE_REVIEW_FILE: reviewCapture,
  })

  const id = 'fresh-instruction-review'
  send(fixture.child, {
    type: 'review_start',
    id,
    convId: 'conv-fresh-review',
    cwd: root,
    model: 'gpt-fixture',
    projectInstructions: 'Prioritize correctness and data-loss risks.',
    workspaceInstructionsRevision: 'fresh-review-workspace-revision',
    allowRepositoryInstructions: false,
    target: { type: 'uncommittedChanges' },
  })
  const terminal = await waitFor(
    () => fixture.events.find((event) => event.id === id
      && (event.type === 'done' || event.type === 'error')),
    'fresh review terminal',
    fixture,
  )

  const start = fs.readFileSync(starts, 'utf8').trim().split('\n').map(JSON.parse).at(-1)
  assertDeveloperInstructions(
    start.developerInstructions,
    'Prioritize correctness and data-loss risks.',
    { workflowAdviceEnabled: false },
  )
  assertNoTransientMcpConfig(start.config, { project_doc_max_bytes: 0 })
  assert.equal(start.dynamicTools.some(
    (tool) => tool.name === 'RecommendMechanicianWorkflow'), false)
  assert.equal(start.sandbox, 'read-only')
  assert.equal(start.approvalPolicy, 'on-request')
  assert.equal('excludeTurns' in start, false)
  const review = JSON.parse(fs.readFileSync(reviewCapture, 'utf8'))
  assert.equal(review.threadId, 'thread-1')
  assert.deepEqual(terminal, { type: 'done', id })
  assertOneTerminal(fixture, id)
})

test('Codex Review rejects forged workflow and presentation calls on its reduced surface', async (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'mechanician-codex-review-workflow-'))
  const starts = path.join(root, 'starts.ndjson')
  const replyCapture = path.join(root, 'workflow-reply.json')
  t.after(() => fs.rmSync(root, { recursive: true, force: true }))
  const fixture = await startAgentd(t, 'review-workflow-forgery', {
    CODEX_FIXTURE_THREAD_START_LOG_FILE: starts,
    CODEX_FIXTURE_REVIEW_TOOL_FILE: replyCapture,
  })

  const id = 'review-workflow-forgery'
  send(fixture.child, {
    type: 'review_start', id, convId: 'conv-review-workflow',
    sessionId: 'codex-tools:ordinary-thread-with-adviser', cwd: root,
    model: 'gpt-fixture', permissionMode: 'bypassPermissions',
    projectInstructions: 'Review only.',
    target: { type: 'uncommittedChanges' },
  })
  const terminal = await waitFor(
    () => fixture.events.find((event) => event.id === id
      && (event.type === 'done' || event.type === 'error')),
    'forged Review workflow terminal', fixture,
  )

  const start = fs.readFileSync(starts, 'utf8').trim().split('\n').map(JSON.parse).at(-1)
  assert.equal(start.dynamicTools.some(
    (tool) => tool.name === 'RecommendMechanicianWorkflow'), false)
  assert.equal(start.dynamicTools.some((tool) => tool.name === 'ShowMechanician'), false)
  assert.doesNotMatch(start.developerInstructions,
    /RecommendMechanicianWorkflow|readiness\.state|ShowMechanician/)
  const replies = fs.readFileSync(replyCapture, 'utf8').trim().split('\n').map(JSON.parse)
  assert.equal(replies.length, 2)
  const workflowReply = replies.find((reply) => reply.id === 9701)
  const showReply = replies.find((reply) => reply.id === 9702)
  assert.equal(workflowReply.result.success, false)
  assert.match(JSON.stringify(workflowReply.result.contentItems),
    /available only to an interactive standard conversation/)
  assert.equal(showReply.result.success, false)
  assert.match(JSON.stringify(showReply.result.contentItems),
    /available only to an interactive standard or Help conversation/)
  assert.equal(fixture.events.some(
    (event) => event.id === id && event.type === 'workflow_advice_request'), false)
  assert.equal(fixture.events.some(
    (event) => event.id === id && event.type === 'workflow_advice_ack'), false)
  assert.equal(fixture.events.some(
    (event) => event.id === id && event.type === 'show_mechanician_request'), false)
  assert.equal(fixture.events.some(
    (event) => event.id === id && event.type === 'show_mechanician_ack'), false)
  assert.deepEqual(terminal, { type: 'done', id })
  assertOneTerminal(fixture, id)
})

test('Codex Review rejects steering, interrupts its provider turn, and rejects unsupported targets', async (t) => {
  const fixture = await startAgentd(t, 'review-hold')
  send(fixture.child, {
    type: 'review_start', id: 'bad-review', target: { type: 'baseBranch', branch: 'main' },
  })
  const invalid = await waitFor(
    () => fixture.events.find((event) => event.id === 'bad-review' && event.type === 'control_error'),
    'unsupported review target rejection', fixture,
  )
  assert.match(invalid.message, /uncommitted changes only/i)
  assert.equal(fixture.events.some((event) => event.id === 'bad-review' && event.type === 'turn_started'), false)

  send(fixture.child, {
    type: 'review_start', id: 'missing-review-workspace',
    cwd: path.join(os.tmpdir(), `mechanician-missing-${randomUUID()}`),
    target: { type: 'uncommittedChanges' },
  })
  const missing = await waitFor(
    () => fixture.events.find((event) => event.id === 'missing-review-workspace'
      && event.type === 'control_error'),
    'missing review workspace rejection', fixture,
  )
  assert.match(missing.message, /workspace is no longer available/i)
  assert.equal(fixture.events.some((event) => event.id === 'missing-review-workspace'
    && event.type === 'turn_started'), false)

  const id = 'review-hold'
  send(fixture.child, {
    type: 'review_start', id, convId: 'conv-review-hold', cwd: process.cwd(),
    target: { type: 'uncommittedChanges' },
  })
  await waitFor(
    () => fixture.events.find((event) => event.id === id && event.type === 'review_started'),
    'held review start', fixture,
  )
  assert.equal(fixture.events.some((event) => event.id === id && event.type === 'session'), false)
  send(fixture.child, {
    type: 'steer', id, turnId: id, steerId: 'review-steer', prompt: 'change direction',
  })
  const rejected = await waitFor(
    () => fixture.events.find((event) => event.id === id
      && event.type === 'steer_rejected' && event.steerId === 'review-steer'),
    'review steering rejection', fixture,
  )
  assert.match(rejected.message, /do not accept guidance/i)

  send(fixture.child, { type: 'interrupt', id: 'interrupt-review', turnId: id })
  const terminal = await waitFor(
    () => fixture.events.find((event) => event.id === id
      && (event.type === 'done' || event.type === 'error')),
    'interrupted review terminal', fixture,
  )
  assert.deepEqual(terminal, { type: 'done', id, interrupted: true })
  assert.equal(fixture.events.some((event) => event.id === id && event.type === 'review_result'), false)
  assertOneTerminal(fixture, id)
})

test('Codex sends exact explicit effort and ignores the legacy hidden Ultra bit', async (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'mechanician-codex-effort-'))
  const capture = path.join(root, 'turns.jsonl')
  t.after(() => fs.rmSync(root, { recursive: true, force: true }))
  const fixture = await startAgentd(t, 'retry-success', {
    CODEX_FIXTURE_TURN_FILE: capture,
  })

  await runTurn(fixture, 'provider-default')
  await runTurn(fixture, 'explicit-effort', { effort: 'low' })
  await runTurn(fixture, 'max-effort', { effort: 'max' })
  await runTurn(fixture, 'native-ultra', { effort: 'ultra' })
  await runTurn(fixture, 'legacy-ultra', { ultracode: true })
  const turns = fs.readFileSync(capture, 'utf8').trim().split('\n').map(JSON.parse)

  assert.equal(Object.hasOwn(turns[0], 'effort'), false)
  assert.equal(turns[1].effort, 'low')
  assert.equal(turns[2].effort, 'max')
  assert.equal(turns[3].effort, 'ultra')
  assert.equal(Object.hasOwn(turns[4], 'effort'), false)
})

test('Codex reconciles a missing Ultra completion from authoritative thread state', async (t) => {
  const fixture = await startAgentd(t, 'reconcile-completed', {
    MECHANICIAN_CODEX_RECONCILE_SILENCE_MS: '35',
    MECHANICIAN_CODEX_RECONCILE_RETRY_MS: '25',
    MECHANICIAN_CODEX_RECONCILE_REQUEST_TIMEOUT_MS: '200',
  })
  send(fixture.child, {
    type: 'send',
    id: 'ultra-missing-terminal',
    convId: 'conv-ultra-missing-terminal',
    prompt: 'PRIVATE_FIXTURE_PROMPT_MUST_NOT_BE_LOGGED',
    model: 'gpt-fixture',
    effort: 'ultra',
  })

  const terminal = await waitFor(
    () => fixture.events.find((event) => event.id === 'ultra-missing-terminal'
      && (event.type === 'done' || event.type === 'error')),
    'reconciled Ultra terminal', fixture,
  )
  assert.deepEqual(terminal, { type: 'done', id: 'ultra-missing-terminal' })
  assertOneTerminal(fixture, 'ultra-missing-terminal')
  assert.deepEqual(
    fixture.events.filter((event) => event.id === 'ultra-missing-terminal'
      && event.type === 'delta').map((event) => event.text),
    ['Recovered final.'],
  )
  assert.equal(fixture.events.filter((event) => event.id === 'ultra-missing-terminal'
    && event.type === 'tool_use' && event.toolUseId === 'recovered-command').length, 1)
  assert.equal(fixture.events.filter((event) => event.id === 'ultra-missing-terminal'
    && event.type === 'tool_result' && event.toolUseId === 'recovered-command').length, 1)
  assert.match(fixture.stderr, /\[codex-lifecycle\]/)
  assert.match(fixture.stderr, /"effort":"ultra"/)
  assert.match(fixture.stderr, /"event":"reconcile_result"/)
  assert.match(fixture.stderr, /"result":"terminal"/)
  assert.doesNotMatch(fixture.stderr, /PRIVATE_FIXTURE_PROMPT_MUST_NOT_BE_LOGGED/)
})

test('Codex keeps a quiet active turn alive and completes it on a later reconciliation', async (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'mechanician-codex-quiet-'))
  const starts = path.join(root, 'starts.txt')
  t.after(() => fs.rmSync(root, { recursive: true, force: true }))
  const fixture = await startAgentd(t, 'reconcile-quiet', {
    CODEX_FIXTURE_START_FILE: starts,
    MECHANICIAN_CODEX_RECONCILE_SILENCE_MS: '30',
    MECHANICIAN_CODEX_RECONCILE_RETRY_MS: '25',
    MECHANICIAN_CODEX_RECONCILE_REQUEST_TIMEOUT_MS: '200',
  })

  const terminal = await runTurn(fixture, 'quiet-ultra', { effort: 'ultra' })
  assert.deepEqual(terminal, { type: 'done', id: 'quiet-ultra' })
  assertOneTerminal(fixture, 'quiet-ultra')
  assert.ok(fixture.events.some((event) => event.id === 'quiet-ultra'
    && event.type === 'provider_status' && event.status === 'provider_active'))
  assert.match(fixture.stderr, /"result":"active"/)
  assert.match(fixture.stderr, /"result":"terminal"/)
  await delay(80)
  assert.equal(
    fs.readFileSync(starts, 'utf8').trim().split('\n').filter(Boolean).length,
    1,
  )
})

test('Codex reconciliation preserves authoritative approval and user-input wait states', async (t) => {
  const fixture = await startAgentd(t, 'reconcile-waits', {
    MECHANICIAN_CODEX_RECONCILE_SILENCE_MS: '30',
    MECHANICIAN_CODEX_RECONCILE_RETRY_MS: '25',
    MECHANICIAN_CODEX_RECONCILE_REQUEST_TIMEOUT_MS: '200',
  })

  const terminal = await runTurn(fixture, 'wait-state-ultra', { effort: 'ultra' })
  const providerStates = fixture.events
    .filter((event) => event.id === 'wait-state-ultra' && event.type === 'provider_status')
    .map((event) => event.providerState)

  assert.deepEqual(terminal, { type: 'done', id: 'wait-state-ultra' })
  assert.ok(providerStates.includes('waitingForApproval'))
  assert.ok(providerStates.includes('waitingForUserInput'))
  assert.match(fixture.stderr, /"activeFlags":\["waitingOnApproval"\]/)
  assert.match(fixture.stderr, /"activeFlags":\["waitingOnUserInput"\]/)
  assertOneTerminal(fixture, 'wait-state-ultra')
})

test('Codex turns absent from an idle provider thread become recoverable orphans', async (t) => {
  const fixture = await startAgentd(t, 'reconcile-orphan', {
    MECHANICIAN_CODEX_RECONCILE_SILENCE_MS: '30',
    MECHANICIAN_CODEX_RECONCILE_REQUEST_TIMEOUT_MS: '200',
  })

  const terminal = await runTurn(fixture, 'orphaned-turn', { effort: 'ultra' })

  assert.equal(terminal.type, 'error')
  assert.equal(terminal.providerError.code, 'turn_orphaned')
  assert.match(terminal.message, /partial output was preserved/i)
  assert.match(fixture.stderr, /"nextState":"recoverableOrphan"/)
  assertOneTerminal(fixture, 'orphaned-turn')
})

test('Codex bounds active-thread ownership disagreement before preserving an orphan', async (t) => {
  const fixture = await startAgentd(t, 'reconcile-mismatch', {
    MECHANICIAN_CODEX_RECONCILE_SILENCE_MS: '30',
    MECHANICIAN_CODEX_RECONCILE_RETRY_MS: '25',
    MECHANICIAN_CODEX_RECONCILE_REQUEST_TIMEOUT_MS: '200',
  })

  const terminal = await runTurn(fixture, 'mismatched-turn')

  assert.equal(terminal.type, 'error')
  assert.equal(terminal.providerError.code, 'turn_orphaned')
  assert.equal((fixture.stderr.match(/"event":"provider_ownership_mismatch"/g) || []).length, 2)
  assert.match(fixture.stderr, /"event":"provider_orphaned"/)
  assertOneTerminal(fixture, 'mismatched-turn')
})

test('lost reconciliation responses restart only after the bounded probe budget', async (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'mechanician-codex-reconcile-loss-'))
  const starts = path.join(root, 'starts.txt')
  t.after(() => fs.rmSync(root, { recursive: true, force: true }))
  const fixture = await startAgentd(t, 'reconcile-timeout', {
    CODEX_FIXTURE_START_FILE: starts,
    MECHANICIAN_CODEX_RECONCILE_SILENCE_MS: '30',
    MECHANICIAN_CODEX_RECONCILE_RETRY_MS: '25',
    MECHANICIAN_CODEX_RECONCILE_REQUEST_TIMEOUT_MS: '25',
    MECHANICIAN_CODEX_RESTART_BASE_MS: '20',
    MECHANICIAN_CODEX_RESTART_MAX_MS: '20',
  })

  const terminal = await runTurn(fixture, 'lost-reconcile-turn', { effort: 'ultra' })

  assert.equal(terminal.type, 'error')
  assert.equal(terminal.providerError.code, 'reconciliation_failed')
  assert.equal((fixture.stderr.match(/"event":"reconcile_failed"/g) || []).length, 2)
  assertOneTerminal(fixture, 'lost-reconcile-turn')
  await waitFor(
    () => fs.readFileSync(starts, 'utf8').trim().split('\n').filter(Boolean).length >= 2,
    'replacement after reconciliation loss', fixture,
  )
})

test('Codex reconciles no-active-turn interrupt rejection without restarting the lane', async (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'mechanician-codex-no-active-'))
  const starts = path.join(root, 'starts.txt')
  const turns = path.join(root, 'turns.jsonl')
  t.after(() => fs.rmSync(root, { recursive: true, force: true }))
  const fixture = await startAgentd(t, 'interrupt-no-active-terminal', {
    CODEX_FIXTURE_START_FILE: starts,
    CODEX_FIXTURE_TURN_FILE: turns,
    MECHANICIAN_CODEX_INTERRUPT_GRACE_MS: '250',
    MECHANICIAN_CODEX_RECONCILE_SILENCE_MS: '1000',
    MECHANICIAN_CODEX_RECONCILE_REQUEST_TIMEOUT_MS: '200',
  })

  send(fixture.child, {
    type: 'send', id: 'interrupt-no-active', convId: 'conv-no-active',
    prompt: 'hold', model: 'gpt-fixture', effort: 'ultra',
  })
  await waitFor(
    () => fs.existsSync(turns) && fs.statSync(turns).size > 0,
    'provider turn before no-active interrupt', fixture,
  )
  send(fixture.child, {
    type: 'interrupt', id: 'stop-no-active', turnId: 'interrupt-no-active',
  })

  const terminal = await waitFor(
    () => fixture.events.find((event) => event.id === 'interrupt-no-active'
      && (event.type === 'done' || event.type === 'error')),
    'no-active interrupt reconciliation', fixture,
  )
  assert.deepEqual(terminal, {
    type: 'done', id: 'interrupt-no-active', interrupted: true,
  })
  assertOneTerminal(fixture, 'interrupt-no-active')
  assert.match(fixture.stderr, /"event":"interrupt_rejected"/)
  assert.match(fixture.stderr, /"reason":"interrupt_no_active_turn"/)
  assert.match(fixture.stderr, /"result":"terminal"/)
  await delay(320)
  assert.equal(
    fs.readFileSync(starts, 'utf8').trim().split('\n').filter(Boolean).length,
    1,
  )
})

test('successful Codex logout remains authoritative if a later account read would fail', async (t) => {
  const fixture = await startAgentd(t, 'logout-read-failure')
  send(fixture.child, { type: 'logout', id: 'logout-1' })

  const logout = await waitFor(
    () => fixture.events.find((event) => event.type === 'logout_ok' && event.id === 'logout-1'),
    'authoritative logout result', fixture,
  )
  await delay(30)

  assert.deepEqual(logout, {
    type: 'logout_ok', id: 'logout-1', loggedIn: false, planType: null,
  })
  assert.equal(fixture.events.some((event) => event.type === 'login_error' && event.id === 'logout-1'), false)
  assert.equal(fixture.events.filter((event) => event.type === 'ready').at(-1).loggedIn, false)
})

test('retrying Codex error notification remains nonterminal and success clears it', async (t) => {
  const fixture = await startAgentd(t, 'retry-success')
  const terminal = await runTurn(fixture)
  await delay(30)

  assert.deepEqual(terminal, { type: 'done', id: 'turn-1' })
  assertOneTerminal(fixture, 'turn-1')
  assert.equal(fixture.events.some((event) => event.type === 'error' && event.id === 'turn-1'), false)
  assert.equal(fixture.events.some((event) => event.type === 'harness_observation'
    && event.id === 'turn-1' && event.event === 'retry'), true)
  assert.equal(fixture.events.some((event) => event.type === 'harness_observation'
    && event.id === 'turn-1' && event.event === 'retry_exhausted'), false)
})

test('a completed Codex child reused by followup_task gets one later-turn terminal', async (t) => {
  const fixture = await startAgentd(t, 'reused-child-followup')
  const sessionId = 'codex-tools:thread-reused-parent'
  assert.deepEqual(await runTurn(fixture, 'reused-child-first', { sessionId }), {
    type: 'done', id: 'reused-child-first',
  })
  assert.deepEqual(await runTurn(fixture, 'reused-child-second', { sessionId }), {
    type: 'done', id: 'reused-child-second',
  })

  const childUpdates = fixture.events.filter((event) => event.type === 'workflow_update'
    && event.id === 'reused-child-second' && event.taskId === 'thread-reused-child')
  const runningIndex = childUpdates.findIndex((event) => (
    event.status === 'running' && event.lastToolName === 'interacted'
  ))
  assert.notEqual(runningIndex, -1, 'Interacted must open a fresh later-turn generation')
  const terminal = (event) => ['completed', 'failed', 'stopped'].includes(event.status)
  assert.equal(childUpdates.slice(0, runningIndex).some((event) => event.status), false,
    'no prior-generation lifecycle may reach the later turn before Interacted')
  assert.equal(childUpdates.filter(terminal).length, 1,
    'the later generation must receive exactly one terminal boundary in total')
  assert.equal(childUpdates.at(-1).status, 'completed')
  assert.equal(childUpdates.some((event) =>
    event.toolEventID === 'reused-child-followup-command'), true)
})

test('legacy sendInput emits one Activity generation for started, completed, and replay', async (t) => {
  const fixture = await startAgentd(t, 'send-input-generation-dedupe')
  const sessionId = 'codex-tools:thread-send-input-parent'
  assert.deepEqual(await runTurn(fixture, 'send-input-first', { sessionId }), {
    type: 'done', id: 'send-input-first',
  })
  assert.deepEqual(await runTurn(fixture, 'send-input-second', { sessionId }), {
    type: 'done', id: 'send-input-second',
  })

  const updates = fixture.events.filter((event) => event.type === 'workflow_update'
    && event.id === 'send-input-second' && event.taskId === 'thread-send-input-child')
  for (const summary of ['started and completed retask', 'completed only retask']) {
    const copies = updates.filter((event) => event.summary === summary)
    assert.equal(copies.filter((event) => (
      event.status === 'running' && event.lastToolName === 'sendInput'
    )).length, 1, `${summary} must open exactly one Activity generation`)
    assert.equal(copies.some((event) => (
      event.status == null && event.lastToolName == null
    )), true, `${summary} replay must preserve metadata without another boundary`)
  }
  assert.equal(updates.some((event) => (
    event.toolEventID === 'send-input-intervening-command'
  )), true, 'intervening child work must survive lifecycle de-duplication')
  assert.equal(updates.filter((event) => (
    event.status === 'running' && event.lastToolName === 'interacted'
  )).length, 1,
  'only the forward Interacted opens; the reverse complementary copy stays metadata-only')
  const forwardUpgrade = updates.filter((event) => event.summary === 'v2 plaintext upgrade')
  assert.equal(forwardUpgrade.filter((event) => event.status === 'running').length, 0,
    'a fast terminal does not turn the delayed complementary sendInput into a new generation')
  assert.equal(forwardUpgrade.some((event) => (
    event.status == null && event.lastToolName == null
  )), true, 'mixed-shape de-duplication preserves plaintext task metadata')
  const reverseRetask = updates.filter((event) => event.summary === 'post-terminal reverse retask')
  assert.equal(reverseRetask.filter((event) => (
    event.status === 'running' && event.lastToolName === 'sendInput'
  )).length, 1, 'terminal clearing preserves the next genuine sendInput retask')
  assert.equal(reverseRetask.some((event) => (
    event.status == null && event.lastToolName == null
  )), true, 'the completed copy remains metadata-only after the reverse-order boundary')
  assert.equal(updates.some((event) => (
    event.toolEventID === 'send-input-v2-forward-command'
  )), true)
  assert.equal(updates.some((event) => (
    event.toolEventID === 'send-input-v2-reverse-command'
  )), true)
  assert.deepEqual(
    updates.filter((event) => event.status).map((event) => event.status),
    ['running', 'running', 'completed', 'running', 'completed', 'running', 'completed'],
    'deferred prior lifecycle and mixed-shape replays cannot add or remove a generation boundary')
})

test('a reused Codex child terminal racing before Interacted closes only after running', async (t) => {
  const fixture = await startAgentd(t, 'reused-child-followup-terminal-race')
  const sessionId = 'codex-tools:thread-reused-parent'
  await runTurn(fixture, 'reused-child-race-first', { sessionId })
  await runTurn(fixture, 'reused-child-race-second', { sessionId })

  const childUpdates = fixture.events.filter((event) => event.type === 'workflow_update'
    && event.id === 'reused-child-race-second' && event.taskId === 'thread-reused-child')
  const lifecycle = childUpdates.filter((event) => event.status)
  assert.deepEqual(lifecycle.map((event) => event.status), ['running', 'failed'])
})

test('unowned reused-child evidence binds only to the root that publishes Interacted', async (t) => {
  const fixture = await startAgentd(t, 'reused-child-followup-concurrent')
  const ownerSession = 'codex-tools:thread-reused-parent'
  await runTurn(fixture, 'reused-child-concurrent-first', { sessionId: ownerSession })
  const [ownerTerminal, otherTerminal] = await Promise.all([
    runTurn(fixture, 'reused-child-concurrent-owner', { sessionId: ownerSession }),
    runTurn(fixture, 'reused-child-concurrent-other', {
      sessionId: 'codex-tools:thread-reused-other',
    }),
  ])
  assert.deepEqual(ownerTerminal, { type: 'done', id: 'reused-child-concurrent-owner' })
  assert.deepEqual(otherTerminal, { type: 'done', id: 'reused-child-concurrent-other' })

  const ownerUpdates = fixture.events.filter((event) => event.type === 'workflow_update'
    && event.id === 'reused-child-concurrent-owner'
    && event.taskId === 'thread-reused-child')
  const otherUpdates = fixture.events.filter((event) => event.type === 'workflow_update'
    && event.id === 'reused-child-concurrent-other'
    && event.taskId === 'thread-reused-child')
  assert.deepEqual(ownerUpdates.filter((event) => event.status)
    .map((event) => event.status), ['running', 'completed'])
  assert.equal(ownerUpdates.some((event) => (
    event.model === 'gpt-concurrent-owner-survives'
  )), true, 'the nonowner terminal must not erase the authoritative child state')
  assert.deepEqual(otherUpdates, [])
})

test('Codex child-thread usage and unique tool items update only the owning agent card', async (t) => {
  const fixture = await startAgentd(t, 'child-metrics')
  const terminal = await runTurn(fixture, 'turn-child-metrics')
  await delay(30)
  assert.deepEqual(terminal, { type: 'done', id: 'turn-child-metrics' })

  const childUpdates = fixture.events.filter((event) => event.type === 'workflow_update'
    && event.id === 'turn-child-metrics' && event.taskId === 'thread-child-metrics')
  const metricUpdates = childUpdates.filter((event) => event.usage)
  const modelUpdates = childUpdates.filter((event) => event.model)
  assert.deepEqual(metricUpdates.at(-1).usage, {
    totalTokens: 1_500,
    inputTokens: 200,
    outputTokens: 100,
    toolUses: 3,
    toolUsesObserved: true,
  })
  assert.deepEqual(metricUpdates.map((event) => event.usage.toolUses).filter(Boolean), [1, 2, 2, 3, 3])
  assert.equal(childUpdates.filter((event) => event.status === 'completed').length, 1)
  assert.equal(childUpdates.at(-1).status, undefined)
  assert.deepEqual(
    modelUpdates.map((event) => event.model),
    ['gpt-child-initial', 'gpt-child-rerouted'])
  assert.deepEqual(
    childUpdates.filter((event) => event.toolEvent).map((event) => ({
      toolEvent: event.toolEvent,
      toolEventID: event.toolEventID,
    })),
    [
      { toolEvent: 'Bash', toolEventID: 'child-command-1' },
      { toolEvent: 'WebSearch', toolEventID: 'child-search-1' },
    ],
  )

  const zeroToolUpdates = fixture.events.filter((event) => event.type === 'workflow_update'
    && event.id === 'turn-child-metrics' && event.taskId === 'thread-child-zero-tools')
  assert.deepEqual(zeroToolUpdates.filter((event) => event.usage).at(-1).usage, {
    totalTokens: 250,
    toolUses: 0,
    toolUsesObserved: true,
  })
  assert.equal(zeroToolUpdates.some((event) => event.usage?.inputTokens === 200
    && event.usage?.outputTokens === 50), true)
  assert.equal(zeroToolUpdates.filter((event) => event.status === 'completed').length, 1)

  const context = fixture.events.filter((event) => event.type === 'context_usage'
    && event.id === 'turn-child-metrics')
  assert.deepEqual(context, [{
    type: 'context_usage', id: 'turn-child-metrics',
    contextTokens: 432, contextWindow: 128_000, model: 'gpt-fixture',
  }])
  assert.equal(fixture.events.some((event) => event.id === 'turn-child-metrics'
    && event.type === 'tool_use' && String(event.toolUseId).startsWith('child-')), false)
  assertOneTerminal(fixture, 'turn-child-metrics')
})

test('Codex replays a bounded early-child metric buffer after parent ownership arrives', async (t) => {
  const fixture = await startAgentd(t, 'child-metrics-early-pressure')
  const terminal = await runTurn(fixture, 'turn-child-pressure')
  assert.deepEqual(terminal, { type: 'done', id: 'turn-child-pressure' })

  const metricUpdates = fixture.events.filter((event) => event.type === 'workflow_update'
    && event.id === 'turn-child-pressure' && event.taskId === 'thread-child-pressure'
    && event.usage)
  assert.deepEqual(metricUpdates.at(-1).usage, {
    totalTokens: 777,
    inputTokens: 700,
    outputTokens: 77,
    toolUses: 128,
    toolUsesObserved: true,
  })
  assert.equal(metricUpdates.length, 2)
  assertOneTerminal(fixture, 'turn-child-pressure')
})

test('Codex preserves nested child lifecycle and metrics without painting child output', async (t) => {
  const fixture = await startAgentd(t, 'child-metrics-nested')
  const terminal = await runTurn(fixture, 'turn-child-nested')
  await delay(30)
  assert.deepEqual(terminal, { type: 'done', id: 'turn-child-nested' })

  const parentUpdates = fixture.events.filter((event) => event.type === 'workflow_update'
    && event.id === 'turn-child-nested' && event.taskId === 'thread-child-parent')
  assert.equal(parentUpdates.some((event) => event.status === 'running'), true)
  assert.equal(parentUpdates.filter((event) => event.status === 'completed').length, 1)

  const grandchildUpdates = fixture.events.filter((event) => event.type === 'workflow_update'
    && event.id === 'turn-child-nested' && event.taskId === 'thread-child-grandchild')
  assert.equal(grandchildUpdates.some((event) => event.status === 'running'), true)
  assert.equal(grandchildUpdates.filter((event) => event.status === 'completed').length, 1)
  assert.deepEqual(grandchildUpdates.filter((event) => event.usage).at(-1).usage, {
    totalTokens: 333,
    toolUses: 1,
    toolUsesObserved: true,
  })
  assert.equal(fixture.events.some((event) => event.id === 'turn-child-nested'
    && event.type === 'tool_use' && event.toolUseId === 'grandchild-command'), false)
  assertOneTerminal(fixture, 'turn-child-nested')
})

test('failed Codex completion uses authoritative message enriched by its error notification', async (t) => {
  const fixture = await startAgentd(t, 'failed-merge')
  const terminal = await runTurn(fixture)
  await delay(30)

  assert.equal(terminal.type, 'error')
  assert.equal(terminal.errorKind, 'server')
  assert.equal(terminal.provider, 'codex')
  assert.equal(terminal.access, 'codex_subscription')
  assert.equal(terminal.message, 'Authoritative final failure.')
  assert.equal(terminal.providerError.status, 503)
  assert.equal(terminal.providerError.codexErrorTag, 'httpConnectionFailed')
  assert.equal(fixture.events.some((event) => event.type === 'harness_observation'
    && event.id === 'turn-1' && event.event === 'internal_error'), true)
  assert.equal(fixture.events.some((event) => event.type === 'harness_observation'
    && event.id === 'turn-1' && event.event === 'retry_exhausted'), false)
  assertOneTerminal(fixture, 'turn-1')
})

test('retrying Codex failure cannot contaminate a later authoritative authentication error', async (t) => {
  const fixture = await startAgentd(t, 'retry-final-auth')
  const terminal = await runTurn(fixture)

  assert.equal(terminal.type, 'error')
  assert.equal(terminal.errorKind, 'authentication')
  assert.equal(terminal.message, 'Sign in again.')
  assert.equal(terminal.providerError.codexErrorTag, 'unauthorized')
  assert.equal(terminal.providerError.status, undefined)
  assertOneTerminal(fixture, 'turn-1')
})

test('same-chunk turn/start response and completion reconcile without stale post-terminal routing', async (t) => {
  const fixture = await startAgentd(t, 'early-completion')
  const terminal = await runTurn(fixture)
  await delay(60)

  assert.deepEqual(terminal, { type: 'done', id: 'turn-1' })
  assert.equal(fixture.events.some((event) => event.id === 'turn-1' && event.type === 'delta'), false)
  assertOneTerminal(fixture, 'turn-1')
})

test('duplicated and reordered lifecycle notifications remain output- and terminal-idempotent', async (t) => {
  const fixture = await startAgentd(t, 'duplicate-reordered')
  const terminal = await runTurn(fixture, 'duplicate-reordered-turn', { effort: 'ultra' })
  await delay(30)

  assert.deepEqual(terminal, { type: 'done', id: 'duplicate-reordered-turn' })
  assert.deepEqual(
    fixture.events.filter((event) => event.id === 'duplicate-reordered-turn'
      && event.type === 'delta').map((event) => event.text),
    ['Exactly once.'],
  )
  assert.equal(fixture.events.filter((event) => event.id === 'duplicate-reordered-turn'
    && event.type === 'tool_use' && event.toolUseId === 'reordered-command').length, 1)
  assert.equal(fixture.events.filter((event) => event.id === 'duplicate-reordered-turn'
    && event.type === 'tool_result' && event.toolUseId === 'reordered-command').length, 1)
  assertOneTerminal(fixture, 'duplicate-reordered-turn')
})

test('same-chunk early approval and dynamic tool requests reconcile to the acknowledged turn', async (t) => {
  const fixture = await startAgentd(t, 'early-requests')
  send(fixture.child, {
    type: 'send', id: 'turn-1', convId: 'conv-turn-1', prompt: 'fixture prompt', model: 'gpt-fixture',
  })
  const permission = await waitFor(
    () => fixture.events.find((event) => event.id === 'turn-1' && event.type === 'permission_request'),
    'early command approval', fixture,
  )
  send(fixture.child, {
    type: 'permission_response', id: 'turn-1', permissionId: permission.permissionId,
    responseId: 'codex_subscription:' + permission.permissionId,
    allow: true, always: false,
  })
  const acknowledgement = await waitFor(
    () => fixture.events.find((event) => event.type === 'permission_response_ack'),
    'permission acknowledgement', fixture,
  )
  const terminal = await waitFor(
    () => fixture.events.find((event) => event.id === 'turn-1'
      && (event.type === 'error' || event.type === 'done')),
    'early request turn terminal', fixture,
  )

  assert.deepEqual(terminal, { type: 'done', id: 'turn-1' })
  assert.deepEqual(acknowledgement, {
    type: 'permission_response_ack', id: 'turn-1',
    permissionId: 'codex_subscription:' + permission.permissionId,
    accepted: true, allow: true, always: false,
  })
  assert.ok(fixture.events.some((event) => event.id === 'turn-1'
    && event.type === 'tool_use' && event.toolUseId === 'early-tool'))
  assert.ok(fixture.events.some((event) => event.id === 'turn-1'
    && event.type === 'tool_result' && event.toolUseId === 'early-tool' && event.status === 'success'))
  assert.ok(fixture.events.some((event) => event.id === 'turn-1'
    && event.type === 'artifact' && event.title === 'Early tool'))
  assertOneTerminal(fixture, 'turn-1')
})

test('Codex interrupt closes only its pending approval once without fabricating a user denial', async (t) => {
  const fixture = await startAgentd(t, 'interrupt-approval')
  send(fixture.child, {
    type: 'send', id: 'turn-a', convId: 'conv-a', prompt: 'first', model: 'gpt-fixture',
  })
  send(fixture.child, {
    type: 'send', id: 'turn-b', convId: 'conv-b', prompt: 'second', model: 'gpt-fixture',
  })
  await waitFor(
    () => fixture.events.filter((event) => event.type === 'permission_request').length === 2,
    'two pending approvals', fixture,
  )
  const permissionA = fixture.events.find((event) => event.type === 'permission_request'
    && event.id === 'turn-a')
  const permissionB = fixture.events.find((event) => event.type === 'permission_request'
    && event.id === 'turn-b')

  send(fixture.child, { type: 'interrupt', id: 'stop-a', turnId: 'turn-a' })
  const closure = await waitFor(
    () => fixture.events.find((event) => event.type === 'interaction_closed'
      && event.id === 'turn-a'),
    'interrupted approval closure', fixture,
  )
  const terminalA = await waitFor(
    () => fixture.events.find((event) => event.id === 'turn-a'
      && (event.type === 'done' || event.type === 'error')),
    'interrupted approval terminal', fixture,
  )
  await waitFor(
    () => /INTERRUPT_APPROVAL_RESPONSE=codex-turn-\d+:decline/.test(fixture.stderr),
    'provider-neutral approval settlement', fixture,
  )

  assert.deepEqual(closure, {
    type: 'interaction_closed', id: 'turn-a', interactionKind: 'permission',
    requestId: permissionA.permissionId, outcome: 'cancelled', reason: 'turn_interrupted',
  })
  assert.deepEqual(terminalA, { type: 'done', id: 'turn-a', interrupted: true })
  assert.ok(fixture.events.indexOf(permissionA) < fixture.events.indexOf(closure))
  assert.ok(fixture.events.indexOf(closure) < fixture.events.indexOf(terminalA))
  assert.equal(fixture.events.filter((event) => event.type === 'interaction_closed'
    && event.id === 'turn-a').length, 1)
  assert.equal(fixture.events.some((event) => event.type === 'interaction_closed'
    && event.id === 'turn-b'), false)
  assert.equal(fixture.events.some((event) => event.type === 'permission_response_ack'), false)
  assert.equal(Object.hasOwn(closure, 'allow'), false)
  assert.equal(Object.hasOwn(closure, 'always'), false)
  assert.equal(Object.hasOwn(closure, 'message'), false)
  assert.equal(fixture.events.some((event) => event.id === 'turn-b'
    && (event.type === 'done' || event.type === 'error')), false)

  send(fixture.child, {
    type: 'permission_response', id: 'turn-b', permissionId: permissionB.permissionId,
    responseId: 'codex_subscription:' + permissionB.permissionId,
    allow: true, always: false,
  })
  const acknowledgementB = await waitFor(
    () => fixture.events.find((event) => event.type === 'permission_response_ack'
      && event.id === 'turn-b'),
    'uninterrupted approval acknowledgement', fixture,
  )
  const terminalB = await waitFor(
    () => fixture.events.find((event) => event.id === 'turn-b'
      && (event.type === 'done' || event.type === 'error')),
    'uninterrupted approval terminal', fixture,
  )

  assert.equal(acknowledgementB.accepted, true)
  assert.equal(acknowledgementB.allow, true)
  assert.deepEqual(terminalB, { type: 'done', id: 'turn-b' })
  assertOneTerminal(fixture, 'turn-a')
  assertOneTerminal(fixture, 'turn-b')
})

test('SIGTERM records pending approval closure before daemon shutdown terminal', async (t) => {
  const fixture = await startAgentd(t, 'interrupt-approval')
  send(fixture.child, {
    type: 'send', id: 'turn-shutdown', convId: 'conv-shutdown',
    prompt: 'pending approval', model: 'gpt-fixture',
  })
  const permission = await waitFor(
    () => fixture.events.find((event) => event.type === 'permission_request'
      && event.id === 'turn-shutdown'),
    'shutdown approval request', fixture,
  )

  fixture.child.kill('SIGTERM')
  const closure = await waitFor(
    () => fixture.events.find((event) => event.type === 'interaction_closed'
      && event.id === 'turn-shutdown'),
    'shutdown approval closure', fixture,
  )
  const terminal = await waitFor(
    () => fixture.events.find((event) => event.id === 'turn-shutdown'
      && (event.type === 'done' || event.type === 'error')),
    'shutdown turn terminal', fixture,
  )
  await waitFor(() => fixture.child.exitCode != null, 'shutdown daemon exit', fixture, 2_000)

  assert.deepEqual(closure, {
    type: 'interaction_closed', id: 'turn-shutdown', interactionKind: 'permission',
    requestId: permission.permissionId, outcome: 'unavailable', reason: 'runtime_stopped',
  })
  assert.ok(fixture.events.indexOf(permission) < fixture.events.indexOf(closure))
  assert.ok(fixture.events.indexOf(closure) < fixture.events.indexOf(terminal))
  assert.equal(fixture.events.filter((event) => event.type === 'interaction_closed'
    && event.id === 'turn-shutdown').length, 1)
  assert.equal(fixture.events.some((event) => event.type === 'permission_response_ack'), false)
  assertOneTerminal(fixture, 'turn-shutdown')
})

test('Codex steer appends guidance to the active provider turn without starting another turn', async (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'mechanician-codex-steer-'))
  const capture = path.join(root, 'steer.json')
  t.after(() => fs.rmSync(root, { recursive: true, force: true }))
  const fixture = await startAgentd(t, 'steer', { CODEX_FIXTURE_STEER_FILE: capture })

  send(fixture.child, {
    type: 'send', id: 'turn-steer', convId: 'conv-steer',
    prompt: 'Start the work.', model: 'gpt-fixture',
  })
  await waitFor(
    () => fixture.events.find((event) => event.type === 'turn_started' && event.id === 'turn-steer'),
    'steer turn acknowledgement', fixture,
  )
  send(fixture.child, {
    type: 'steer', id: 'turn-steer', turnId: 'turn-steer', steerId: 'steer-1',
    prompt: 'Keep the current visual design.',
  })

  const acknowledgement = await waitFor(
    () => fixture.events.find((event) => event.type === 'steer_ack' && event.steerId === 'steer-1'),
    'steer acknowledgement', fixture,
  )
  const terminal = await waitFor(
    () => fixture.events.find((event) => event.id === 'turn-steer'
      && (event.type === 'done' || event.type === 'error')),
    'steered turn terminal', fixture,
  )
  const request = JSON.parse(fs.readFileSync(capture, 'utf8'))

  assert.deepEqual(acknowledgement, {
    type: 'steer_ack', id: 'turn-steer', steerId: 'steer-1',
  })
  assert.deepEqual(request.input, [{ type: 'text', text: 'Keep the current visual design.' }])
  assert.equal(request.expectedTurnId, 'codex-turn-1')
  assert.equal(fixture.events.filter((event) => event.type === 'turn_started').length, 1)
  assert.ok(fixture.events.some((event) => event.id === 'turn-steer'
    && event.type === 'delta' && event.text === 'Guidance received.'))
  assert.deepEqual(terminal, { type: 'done', id: 'turn-steer' })
})

test('early unanswered approval cannot block following terminal replay and is declined', async (t) => {
  const fixture = await startAgentd(t, 'early-approval-completion')
  const terminal = await runTurn(fixture)
  await waitFor(
    () => fixture.stderr.includes('EARLY_APPROVAL_RESPONSE=decline'),
    'declined early approval response', fixture,
  )

  assert.deepEqual(terminal, { type: 'done', id: 'turn-1' })
  assert.ok(fixture.events.some((event) => event.id === 'turn-1' && event.type === 'permission_request'))
  assertOneTerminal(fixture, 'turn-1')
})

test('bounded early-event queue preserves completion beyond both entry and byte pressure', async (t) => {
  const fixture = await startAgentd(t, 'early-pressure')
  const terminal = await runTurn(fixture)
  const deltas = fixture.events.filter((event) => event.id === 'turn-1' && event.type === 'delta')

  assert.deepEqual(terminal, { type: 'done', id: 'turn-1' })
  assert.ok(deltas.length > 0)
  assert.ok(deltas.length < 128)
  assert.ok(deltas.reduce((total, event) => total + Buffer.byteLength(event.text, 'utf8'), 0) < 256 * 1024)
  assertOneTerminal(fixture, 'turn-1')
})

test('oversized early terminal fails deterministically instead of dropping completion', async (t) => {
  const fixture = await startAgentd(t, 'early-terminal-overflow')
  const terminal = await runTurn(fixture)

  assert.equal(terminal.type, 'error')
  assert.equal(terminal.providerError.code, 'early_event_overflow')
  assert.match(terminal.message, /too much turn data/i)
  assertOneTerminal(fixture, 'turn-1')
})

test('delayed events from an old turn cannot fall back to a newer turn on the same thread', async (t) => {
  const fixture = await startAgentd(t, 'sequential-late')
  await runTurn(fixture, 'turn-a')
  const session = await waitFor(
    () => fixture.events.find((event) => event.id === 'turn-a' && event.type === 'session')?.sessionId,
    'first turn session', fixture,
  )
  send(fixture.child, {
    type: 'send', id: 'turn-b', convId: 'conv-b', prompt: 'second',
    model: 'gpt-fixture', sessionId: session,
  })
  const terminalB = await waitFor(
    () => fixture.events.find((event) => event.id === 'turn-b'
      && (event.type === 'error' || event.type === 'done')),
    'second turn terminal', fixture,
  )
  await delay(30)

  assert.deepEqual(terminalB, { type: 'done', id: 'turn-b' })
  assert.deepEqual(
    fixture.events.filter((event) => event.id === 'turn-b' && event.type === 'delta')
      .map((event) => event.text),
    ['B'],
  )
  assert.equal(fixture.events.some((event) => event.id === 'turn-b'
    && (event.type === 'permission_request' || event.type === 'tool_use' || event.type === 'artifact')), false)
  assertOneTerminal(fixture, 'turn-a')
  assertOneTerminal(fixture, 'turn-b')
})

test('unexpected Codex App Server exit terminalizes all active turns once and releases approvals', async (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'mechanician-codex-restart-'))
  const starts = path.join(root, 'starts.txt')
  t.after(() => fs.rmSync(root, { recursive: true, force: true }))
  const fixture = await startAgentd(t, 'exit-active', {
    CODEX_FIXTURE_START_FILE: starts,
    MECHANICIAN_CODEX_RESTART_BASE_MS: '20',
    MECHANICIAN_CODEX_RESTART_MAX_MS: '20',
  })
  send(fixture.child, { type: 'send', id: 'turn-a', convId: 'conv-a', prompt: 'first' })
  send(fixture.child, { type: 'send', id: 'turn-b', convId: 'conv-b', prompt: 'second' })
  await waitFor(
    () => fixture.events.filter((event) => event.type === 'permission_request').length === 2,
    'two pending Codex approvals', fixture,
  )
  const terminalA = await waitFor(
    () => fixture.events.find((event) => event.id === 'turn-a' && event.type === 'error'),
    'first exit terminal', fixture,
  )
  const terminalB = await waitFor(
    () => fixture.events.find((event) => event.id === 'turn-b' && event.type === 'error'),
    'second exit terminal', fixture,
  )
  await delay(50)

  assert.equal(terminalA.provider, 'codex')
  assert.equal(terminalB.provider, 'codex')
  assert.equal(terminalA.access, 'codex_subscription')
  assert.equal(terminalB.access, 'codex_subscription')
  assert.equal(terminalA.providerError.code, 'app_server_exit')
  assert.equal(terminalB.providerError.code, 'app_server_exit')
  assertOneTerminal(fixture, 'turn-a')
  assertOneTerminal(fixture, 'turn-b')

  await waitFor(
    () => fs.readFileSync(starts, 'utf8').trim().split('\n').filter(Boolean).length >= 2,
    'replacement Codex App Server launch', fixture,
  )
  await waitFor(
    () => fixture.events.filter((event) => event.type === 'ready' && event.mode === 'sdk').length >= 2,
    'replacement Codex ready event', fixture, 30000,
  )
  assert.ok(fixture.events.some((event) => event.type === 'ready'
    && event.mode === 'starting' && event.loggedIn === true))
  assert.equal(fixture.events.filter((event) => event.type === 'ready').at(-1).loggedIn, true)
})

test('Codex stops automatic respawns when post-handshake children remain unstable', async (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'mechanician-codex-restart-budget-'))
  const starts = path.join(root, 'starts.txt')
  t.after(() => fs.rmSync(root, { recursive: true, force: true }))
  const fixture = await startAgentd(t, 'ready-exit-loop', {
    CODEX_FIXTURE_START_FILE: starts,
    MECHANICIAN_CODEX_RESTART_BASE_MS: '10',
    MECHANICIAN_CODEX_RESTART_MAX_MS: '10',
    MECHANICIAN_CODEX_RESTART_LIMIT: '3',
    MECHANICIAN_CODEX_RESTART_STABLE_MS: '2000',
  })

  const paused = await waitFor(
    () => fixture.events.find((event) => event.type === 'info'
      && /automatic restart paused/.test(event.message)),
    'bounded Codex restart pause', fixture, 30000,
  )
  assert.match(paused.message, /after 3 unstable App Server restarts/)
  assert.equal(
    fs.readFileSync(starts, 'utf8').trim().split('\n').filter(Boolean).length,
    4,
    'the initial child plus three automatic replacements are the entire unstable burst',
  )
  assert.equal(fixture.events.filter((event) => event.type === 'ready').at(-1).mode, 'unavailable')
  assert.equal(fixture.events.filter((event) => event.type === 'ready').at(-1).loggedIn, true)
  assert.match(fixture.stderr, /restart 3\/3 scheduled/)
  assert.match(fixture.stderr, /automatic restart paused/)

  await delay(100)
  assert.equal(
    fs.readFileSync(starts, 'utf8').trim().split('\n').filter(Boolean).length,
    4,
    'no timer may survive the open circuit and start a fifth child',
  )

  send(fixture.child, {
    type: 'send', id: 'explicit-restart-after-pause', convId: 'conv-restart', prompt: 'retry',
  })
  await waitFor(
    () => fs.readFileSync(starts, 'utf8').trim().split('\n').filter(Boolean).length === 5,
    'one explicit post-pause retry', fixture,
  )
  await waitFor(
    () => fixture.events.filter((event) => event.type === 'info'
      && /automatic restart paused/.test(event.message)).length === 2,
    'post-demand restart pause', fixture,
  )
  await delay(100)
  assert.equal(
    fs.readFileSync(starts, 'utf8').trim().split('\n').filter(Boolean).length,
    5,
    'explicit demand gets one retry, never a fresh automatic burst',
  )
})

test('Codex keeps the active lane warm and reaps only an inactive App Server child', async (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'mechanician-codex-residency-'))
  const starts = path.join(root, 'starts.txt')
  const pidFile = path.join(root, 'codex.pid')
  t.after(() => fs.rmSync(root, { recursive: true, force: true }))
  const fixture = await startAgentd(t, 'retry-success', {
    CODEX_FIXTURE_START_FILE: starts,
    CODEX_FIXTURE_PID_FILE: pidFile,
    MECHANICIAN_CODEX_INACTIVE_IDLE_MS: '50',
  })
  const firstPid = Number(fs.readFileSync(pidFile, 'utf8'))

  await delay(120)
  assert.doesNotThrow(() => process.kill(firstPid, 0), 'the selected lane stays resident')
  assert.equal(fs.readFileSync(starts, 'utf8').trim().split('\n').filter(Boolean).length, 1)

  send(fixture.child, { type: 'provider_residency', active: false })
  await waitFor(() => {
    try { process.kill(firstPid, 0); return false } catch { return true }
  }, 'inactive App Server exit', fixture, 2000)
  await delay(100)
  assert.equal(
    fs.readFileSync(starts, 'utf8').trim().split('\n').filter(Boolean).length,
    1,
    'intentional idle release never schedules an automatic replacement',
  )
  assert.doesNotMatch(fixture.stderr, /restarting after its App Server stopped/)

  send(fixture.child, { type: 'ping', id: 'residency-ping' })
  await waitFor(
    () => fixture.events.find((event) => event.type === 'pong' && event.id === 'residency-ping'),
    'owning agentd pong after child reap', fixture,
  )

  send(fixture.child, { type: 'provider_residency', active: true })
  await waitFor(
    () => fs.readFileSync(starts, 'utf8').trim().split('\n').filter(Boolean).length === 2,
    'one App Server wake', fixture, 30000,
  )
  await waitFor(
    () => fixture.events.filter((event) => event.type === 'ready'
      && event.mode === 'sdk').length >= 2,
    'woken App Server ready', fixture,
  )
  const secondPid = Number(fs.readFileSync(pidFile, 'utf8'))
  assert.notEqual(secondPid, firstPid)
  assert.doesNotThrow(() => process.kill(secondPid, 0))

  send(fixture.child, { type: 'provider_residency', active: true })
  send(fixture.child, { type: 'provider_residency', active: true })
  await delay(100)
  assert.equal(
    fs.readFileSync(starts, 'utf8').trim().split('\n').filter(Boolean).length,
    2,
    'ready-time active advisories are idempotent',
  )
})

test('Codex idle reaping waits for an accepted turn to finish', async (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'mechanician-codex-residency-turn-'))
  const starts = path.join(root, 'starts.txt')
  const pidFile = path.join(root, 'codex.pid')
  t.after(() => fs.rmSync(root, { recursive: true, force: true }))
  const fixture = await startAgentd(t, 'residency-hold', {
    CODEX_FIXTURE_START_FILE: starts,
    CODEX_FIXTURE_PID_FILE: pidFile,
    MECHANICIAN_CODEX_INACTIVE_IDLE_MS: '50',
  })
  const codexPid = Number(fs.readFileSync(pidFile, 'utf8'))

  send(fixture.child, {
    type: 'send', id: 'residency-turn', convId: 'conv-residency-turn',
    prompt: 'hold past the inactive deadline', model: 'gpt-fixture',
  })
  await waitFor(
    () => fixture.events.find((event) => event.id === 'residency-turn'
      && event.type === 'status' && event.status === 'thinking'),
    'held Codex turn', fixture,
  )
  send(fixture.child, { type: 'provider_residency', active: false })

  await delay(140)
  assert.doesNotThrow(
    () => process.kill(codexPid, 0),
    'an accepted turn keeps its inactive App Server alive past the idle deadline',
  )

  send(fixture.child, {
    type: 'interrupt', id: 'stop-residency-turn', turnId: 'residency-turn',
  })
  const terminal = await waitFor(
    () => fixture.events.find((event) => event.id === 'residency-turn'
      && (event.type === 'done' || event.type === 'error')),
    'held Codex turn terminal', fixture,
  )
  assert.deepEqual(terminal, { type: 'done', id: 'residency-turn', interrupted: true })
  assertOneTerminal(fixture, 'residency-turn')
  await waitFor(() => {
    try { process.kill(codexPid, 0); return false } catch { return true }
  }, 'inactive App Server exit after turn terminal', fixture, 2_000)
  assert.equal(
    fs.readFileSync(starts, 'utf8').trim().split('\n').filter(Boolean).length,
    1,
    'turn completion does not auto-replace an inactive App Server',
  )

  send(fixture.child, { type: 'ping', id: 'residency-turn-ping' })
  await waitFor(
    () => fixture.events.find((event) => event.type === 'pong'
      && event.id === 'residency-turn-ping'),
    'owning agentd pong after turn-scoped reap', fixture,
  )
})

test('an explicit inactive-lane turn wakes one App Server and cannot reuse stale warm state', async (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'mechanician-codex-residency-warm-'))
  const starts = path.join(root, 'starts.txt')
  const pidFile = path.join(root, 'codex.pid')
  const resumes = path.join(root, 'resumes.ndjson')
  t.after(() => fs.rmSync(root, { recursive: true, force: true }))
  const fixture = await startAgentd(t, 'retry-success', {
    CODEX_FIXTURE_START_FILE: starts,
    CODEX_FIXTURE_PID_FILE: pidFile,
    CODEX_FIXTURE_RESUME_LOG_FILE: resumes,
    MECHANICIAN_CODEX_INACTIVE_IDLE_MS: '50',
  })
  const firstPid = Number(fs.readFileSync(pidFile, 'utf8'))

  send(fixture.child, {
    type: 'prewarm', id: 'residency-prewarm',
    sessionId: 'codex-tools:residency-thread', model: 'gpt-fixture', cwd: root,
    permissionMode: 'default', projectInstructions: 'Keep this thread exact.',
    workspaceInstructionsRevision: 'residency-revision',
  })
  await waitFor(
    () => fs.existsSync(resumes)
      && fs.readFileSync(resumes, 'utf8').trim().split('\n').filter(Boolean).length === 1,
    'initial residency prewarm', fixture,
  )
  send(fixture.child, { type: 'provider_residency', active: false })
  await waitFor(() => {
    try { process.kill(firstPid, 0); return false } catch { return true }
  }, 'initial inactive App Server exit', fixture, 2_000)

  const terminal = await runTurn(fixture, 'inactive-demand-turn', {
    sessionId: 'codex-tools:residency-thread', model: 'gpt-fixture', cwd: root,
    permissionMode: 'default', projectInstructions: 'Keep this thread exact.',
    workspaceInstructionsRevision: 'residency-revision',
  })
  assert.deepEqual(terminal, { type: 'done', id: 'inactive-demand-turn' })
  assert.equal(
    fs.readFileSync(starts, 'utf8').trim().split('\n').filter(Boolean).length,
    2,
    'one explicit turn demand starts exactly one replacement',
  )
  const resumeRequests = fs.readFileSync(resumes, 'utf8')
    .trim().split('\n').filter(Boolean).map(JSON.parse)
  assert.equal(resumeRequests.length, 2, 'the prior process warm proof is never reused')
  assert.equal(resumeRequests[0].threadId, 'residency-thread')
  assert.equal(resumeRequests[1].threadId, 'residency-thread')

  const secondPid = Number(fs.readFileSync(pidFile, 'utf8'))
  assert.notEqual(secondPid, firstPid)
  await waitFor(() => {
    try { process.kill(secondPid, 0); return false } catch { return true }
  }, 'inactive replacement exit after demanded turn', fixture, 2_000)
  await delay(80)
  assert.equal(
    fs.readFileSync(starts, 'utf8').trim().split('\n').filter(Boolean).length,
    2,
    'completed inactive-lane demand does not schedule another replacement',
  )
})

test('an inactive model-catalog RPC spans the idle deadline and reaps on response', async (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'mechanician-codex-residency-rpc-'))
  const starts = path.join(root, 'starts.txt')
  const pidFile = path.join(root, 'codex.pid')
  t.after(() => fs.rmSync(root, { recursive: true, force: true }))
  const fixture = await startAgentd(t, 'residency-slow-catalog', {
    CODEX_FIXTURE_START_FILE: starts,
    CODEX_FIXTURE_PID_FILE: pidFile,
    MECHANICIAN_CODEX_INACTIVE_IDLE_MS: '50',
  })
  const firstPid = Number(fs.readFileSync(pidFile, 'utf8'))
  send(fixture.child, { type: 'provider_residency', active: false })
  await waitFor(() => {
    try { process.kill(firstPid, 0); return false } catch { return true }
  }, 'sleeping catalog fixture', fixture, 2_000)

  send(fixture.child, { type: 'model_catalog', id: 'inactive-catalog' })
  await waitFor(
    () => fs.readFileSync(starts, 'utf8').trim().split('\n').filter(Boolean).length === 2,
    'catalog-demand App Server wake', fixture, 30_000,
  )
  const secondPid = Number(fs.readFileSync(pidFile, 'utf8'))
  assert.notEqual(secondPid, firstPid)
  await delay(80)
  assert.doesNotThrow(
    () => process.kill(secondPid, 0),
    'the outbound model/list RPC holds the child beyond the expired idle deadline',
  )
  const catalog = await waitFor(
    () => fixture.events.find((event) => event.type === 'model_catalog'
      && event.id === 'inactive-catalog'),
    'inactive catalog response', fixture,
  )
  assert.deepEqual(catalog.models.map((model) => model.id), ['gpt-fixture'])
  await waitFor(() => {
    try { process.kill(secondPid, 0); return false } catch { return true }
  }, 'catalog child exit after response', fixture, 2_000)
  await delay(80)
  assert.equal(
    fs.readFileSync(starts, 'utf8').trim().split('\n').filter(Boolean).length,
    2,
    'an inactive control RPC never leaves a replacement loop',
  )

  send(fixture.child, { type: 'ping', id: 'inactive-catalog-ping' })
  await waitFor(
    () => fixture.events.find((event) => event.type === 'pong'
      && event.id === 'inactive-catalog-ping'),
    'owning agentd pong after catalog rental', fixture,
  )
})

test('an inactive Codex login hold survives the idle deadline without reopening restarts', async (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'mechanician-codex-residency-login-'))
  const starts = path.join(root, 'starts.txt')
  const pidFile = path.join(root, 'codex.pid')
  t.after(() => fs.rmSync(root, { recursive: true, force: true }))
  const fixture = await startAgentd(t, 'signed-out', {
    CODEX_FIXTURE_START_FILE: starts,
    CODEX_FIXTURE_PID_FILE: pidFile,
    MECHANICIAN_CODEX_INACTIVE_IDLE_MS: '50',
    MECHANICIAN_CODEX_RESTART_BASE_MS: '20',
    MECHANICIAN_CODEX_RESTART_MAX_MS: '20',
  })
  const codexPid = Number(fs.readFileSync(pidFile, 'utf8'))

  send(fixture.child, { type: 'login_start', id: 'inactive-login' })
  await waitFor(
    () => fixture.events.find((event) => event.type === 'login_url'
      && event.id === 'inactive-login'),
    'inactive-lane login URL', fixture,
  )
  send(fixture.child, { type: 'provider_residency', active: false })
  await delay(140)
  assert.doesNotThrow(
    () => process.kill(codexPid, 0),
    'a browser login hold keeps the inactive App Server alive',
  )

  process.kill(codexPid, 'SIGTERM')
  const terminal = await waitFor(
    () => fixture.events.find((event) => event.type === 'login_error'
      && event.id === 'inactive-login'),
    'login terminal after inactive provider exit', fixture,
  )
  assert.match(terminal.message, /stopped during sign-in/)
  await delay(120)
  assert.equal(
    fs.readFileSync(starts, 'utf8').trim().split('\n').filter(Boolean).length,
    1,
    'an inactive browser-flow exit never starts an automatic replacement',
  )

  send(fixture.child, { type: 'ping', id: 'inactive-login-ping' })
  await waitFor(
    () => fixture.events.find((event) => event.type === 'pong'
      && event.id === 'inactive-login-ping'),
    'owning agentd pong after inactive login exit', fixture,
  )
})

test('sleeping MCP status stays cold while explicit OAuth holds and then releases the lane', async (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'mechanician-codex-residency-oauth-'))
  const starts = path.join(root, 'starts.txt')
  const pidFile = path.join(root, 'codex.pid')
  const support = path.join(root, 'support')
  writeConfiguredMcpSidecar(support)
  t.after(() => fs.rmSync(root, { recursive: true, force: true }))
  const fixture = await startAgentd(t, 'retry-success', {
    MECHANICIAN_SUPPORT_DIR: support,
    CODEX_FIXTURE_START_FILE: starts,
    CODEX_FIXTURE_PID_FILE: pidFile,
    MECHANICIAN_CODEX_INACTIVE_IDLE_MS: '50',
  })
  const firstPid = Number(fs.readFileSync(pidFile, 'utf8'))
  send(fixture.child, { type: 'provider_residency', active: false })
  await waitFor(() => {
    try { process.kill(firstPid, 0); return false } catch { return true }
  }, 'sleeping OAuth fixture', fixture, 2_000)

  send(fixture.child, { type: 'mcp_status', id: 'sleeping-mcp-status' })
  await waitFor(
    () => fixture.events.find((event) => event.type === 'mcp_status_result'
      && event.id === 'sleeping-mcp-status'),
    'sleeping MCP status result', fixture,
  )
  await delay(80)
  assert.equal(
    fs.readFileSync(starts, 'utf8').trim().split('\n').filter(Boolean).length,
    1,
    'a read-only status refresh does not wake the persistent child',
  )

  send(fixture.child, exactConfiguredMcpControl(
    'mcp_authorize', 'inactive-mcp-authorize'))
  const url = await waitFor(
    () => fixture.events.find((event) => event.type === 'mcp_authorize_url'
      && event.id === 'inactive-mcp-authorize'),
    'inactive MCP authorization URL', fixture, 30_000,
  )
  assert.equal(url.url, 'https://example.test/codex-mcp-login')
  assert.equal(
    fs.readFileSync(starts, 'utf8').trim().split('\n').filter(Boolean).length,
    2,
    'explicit OAuth wakes exactly one App Server',
  )
  const secondPid = Number(fs.readFileSync(pidFile, 'utf8'))
  await delay(140)
  assert.doesNotThrow(
    () => process.kill(secondPid, 0),
    'the browser OAuth waiter holds the inactive App Server past its deadline',
  )

  send(fixture.child, exactConfiguredMcpControl(
    'mcp_authorize_cancel', 'cancel-inactive-mcp', {
      attemptId: 'inactive-mcp-authorize-attempt', operation: 'authorize',
    }))
  await waitFor(
    () => fixture.events.find((event) => event.type === 'mcp_authorize_cancel_ok'
      && event.id === 'cancel-inactive-mcp'),
    'inactive MCP authorization cancel', fixture,
  )
  await waitFor(() => {
    try { process.kill(secondPid, 0); return false } catch { return true }
  }, 'OAuth child exit after cancel', fixture, 2_000)
  await delay(80)
  assert.equal(
    fs.readFileSync(starts, 'utf8').trim().split('\n').filter(Boolean).length,
    2,
    'OAuth cancellation does not schedule a replacement',
  )
})

test('Codex OAuth success stays behind the live MCP reload boundary', async (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'mechanician-codex-oauth-reload-'))
  const reload = path.join(root, 'reload.txt')
  const support = path.join(root, 'support')
  writeConfiguredMcpSidecar(support)
  t.after(() => fs.rmSync(root, { recursive: true, force: true }))
  const fixture = await startAgentd(t, 'oauth-complete-reload', {
    MECHANICIAN_SUPPORT_DIR: support,
    CODEX_FIXTURE_MCP_RELOAD_FILE: reload,
  })

  send(fixture.child, exactConfiguredMcpControl(
    'mcp_authorize', 'oauth-reload-boundary'))
  await waitFor(
    () => fixture.events.find((event) => event.type === 'mcp_authorize_url'
      && event.id === 'oauth-reload-boundary'),
    'Codex MCP authorization URL', fixture,
  )
  await waitFor(
    () => fs.existsSync(reload),
    'Codex MCP reload start', fixture,
  )
  assert.equal(
    fixture.events.some((event) => event.type === 'mcp_authorize_ok'
      && event.id === 'oauth-reload-boundary'),
    false,
    'credential completion is not tool readiness while the live provider reload is unresolved')

  await waitFor(
    () => fixture.events.find((event) => event.type === 'mcp_authorize_ok'
      && event.id === 'oauth-reload-boundary'),
    'post-reload Codex MCP authorization terminal', fixture,
  )
  const terminal = fixture.events.find((event) => event.type === 'mcp_authorize_ok'
    && event.id === 'oauth-reload-boundary')
  assert.equal(terminal.status, 'connected')
  assert.equal(terminal.tools, 1)
  assert.equal(terminal.changeId, 'oauth-reload-boundary-attempt')
  assert.equal(terminal.source, 'configured')
  assert.equal(terminal.serverId, configuredMcpServerId)
  assert.equal(terminal.accountInstanceId, mcpAccountInstanceId)
  assert.equal(terminal.routeIdentity, codexMcpRouteIdentity)
  assert.ok(fixture.events.some((event) => event.type === 'mcp_credentials_changed'
    && event.changeId === terminal.changeId
    && event.activation === 'ready'
    && event.tools === 1))
})

test('OAuth completion queued first fully settles before account reload publishes account B', async (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'mechanician-codex-oauth-account-order-'))
  const support = path.join(root, 'support')
  const reloadStarted = path.join(root, 'reload-started')
  const releaseReload = path.join(root, 'release-reload')
  const starts = path.join(root, 'starts.ndjson')
  const authorizationId = 'oauth-first-account-second'
  const attemptId = `${authorizationId}-attempt`
  writeConfiguredMcpSidecar(support)
  t.after(() => fs.rmSync(root, {
    recursive: true, force: true, maxRetries: 20, retryDelay: 10,
  }))
  const fixture = await startAgentd(t, 'oauth-complete-reload', {
    MECHANICIAN_SUPPORT_DIR: support,
    CODEX_FIXTURE_MCP_RELOAD_FILE: reloadStarted,
    CODEX_FIXTURE_MCP_RELOAD_RELEASE_FILE: releaseReload,
    CODEX_FIXTURE_START_FILE: starts,
  })

  send(fixture.child, exactConfiguredMcpControl('mcp_authorize', authorizationId))
  await waitFor(
    () => fixture.events.find((event) => event.type === 'mcp_authorize_url'
      && event.id === authorizationId),
    'OAuth URL before account ordering', fixture,
  )
  await waitFor(() => fs.existsSync(reloadStarted), 'held OAuth completion reload', fixture)
  send(fixture.child, {
    type: 'account_reload', id: 'account-second-after-oauth',
    accountInstanceId: replacementMcpAccountInstanceId,
  })
  await delay(75)
  assert.equal(fixture.events.some((event) => event.type === 'account_reload_ok'
    && event.id === 'account-second-after-oauth'), false,
  'account B must remain behind the already-queued OAuth completion generation')
  assert.equal(
    fs.readFileSync(starts, 'utf8').trim().split('\n').filter(Boolean).length,
    1,
    'account B cannot replace the stream while OAuth A reload is held',
  )

  fs.writeFileSync(releaseReload, 'released')
  const oauth = await waitFor(
    () => fixture.events.find((event) => event.type === 'mcp_authorize_ok'
      && event.id === authorizationId),
    'OAuth A terminal before account B', fixture, 30_000,
  )
  const account = await waitFor(
    () => fixture.events.find((event) => event.type === 'account_reload_ok'
      && event.id === 'account-second-after-oauth'),
    'account B terminal after OAuth A', fixture, 30_000,
  )
  const oauthIndex = fixture.events.indexOf(oauth)
  const accountReadyIndex = fixture.events.findIndex((event) => event.type === 'ready'
    && event.accountInstanceId === replacementMcpAccountInstanceId.toLowerCase())
  const accountIndex = fixture.events.indexOf(account)
  assert.ok(oauthIndex >= 0 && accountReadyIndex > oauthIndex && accountIndex > accountReadyIndex)
  assert.equal(oauth.changeId, attemptId)
  assert.equal(oauth.tools, 1)
  assert.deepEqual(readCodexMcpCredentialMarker(fixture), {
    schemaVersion: 1,
    revision: attemptId,
    servers: { [configuredMcpServerId]: attemptId },
  })
  assert.equal(fixture.events.slice(accountReadyIndex + 1).some((event) =>
    event.type === 'mcp_credentials_changed' && event.changeId === attemptId), false,
  'OAuth A cannot publish again after account B becomes ready')
})

test('late Codex OAuth success after exact cancellation keeps the cancelled attempt identity', async (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'mechanician-codex-oauth-late-cancel-'))
  const support = path.join(root, 'support')
  writeConfiguredMcpSidecar(support)
  t.after(() => fs.rmSync(root, { recursive: true, force: true, maxRetries: 20, retryDelay: 10 }))
  const fixture = await startAgentd(t, 'oauth-complete-after-cancel', {
    MECHANICIAN_SUPPORT_DIR: support,
  })
  const authorizationId = 'late-cancelled-oauth'
  const attemptId = `${authorizationId}-attempt`

  send(fixture.child, exactConfiguredMcpControl('mcp_authorize', authorizationId))
  await waitFor(
    () => fixture.events.find((event) => event.type === 'mcp_authorize_url'
      && event.id === authorizationId),
    'late-cancel Codex MCP authorization URL', fixture,
  )
  send(fixture.child, exactConfiguredMcpControl(
    'mcp_authorize_cancel', 'cancel-late-codex-oauth', { attemptId }))
  const cancellation = await waitFor(
    () => fixture.events.find((event) => event.type === 'mcp_authorize_cancel_ok'
      && event.id === 'cancel-late-codex-oauth'),
    'exact Codex MCP authorization cancellation', fixture,
  )

  const exactIdentity = {
    name: 'fixture-server', attemptId, changeId: attemptId, source: 'configured',
    serverId: configuredMcpServerId, accountInstanceId: mcpAccountInstanceId,
    routeIdentity: codexMcpRouteIdentity, operation: 'authorize',
  }
  assert.deepEqual({
    name: cancellation.name, attemptId: cancellation.attemptId,
    changeId: cancellation.changeId, source: cancellation.source,
    serverId: cancellation.serverId, accountInstanceId: cancellation.accountInstanceId,
    routeIdentity: cancellation.routeIdentity, operation: cancellation.operation,
  }, exactIdentity)

  const activating = await waitFor(
    () => fixture.events.find((event) => event.type === 'mcp_credentials_changed'
      && event.changeId === attemptId && event.activation === 'activating'),
    'late cancelled OAuth activating event', fixture,
  )
  const ready = await waitFor(
    () => fixture.events.find((event) => event.type === 'mcp_credentials_changed'
      && event.changeId === attemptId && event.activation === 'ready'),
    'late cancelled OAuth ready event', fixture,
  )
  for (const event of [activating, ready]) {
    assert.deepEqual({
      name: event.name, changeId: event.changeId, source: event.source,
      serverId: event.serverId, accountInstanceId: event.accountInstanceId,
      routeIdentity: event.routeIdentity, operation: event.operation,
    }, {
      name: exactIdentity.name, changeId: exactIdentity.changeId, source: exactIdentity.source,
      serverId: exactIdentity.serverId, accountInstanceId: exactIdentity.accountInstanceId,
      routeIdentity: exactIdentity.routeIdentity, operation: exactIdentity.operation,
    })
  }
  assert.equal(ready.status, 'connected')
  assert.equal(ready.tools, 1)
  assert.equal(fixture.events.some((event) => event.type === 'mcp_authorize_ok'
    && event.id === authorizationId), false,
  'cancellation retires the request owner even though the provider later changes credentials')
  assert.deepEqual(readCodexMcpCredentialMarker(fixture), {
    schemaVersion: 1,
    revision: attemptId,
    servers: { [configuredMcpServerId]: attemptId },
  })
})

test('late Codex OAuth success after timeout keeps the timed-out attempt identity', async (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'mechanician-codex-oauth-late-timeout-'))
  const support = path.join(root, 'support')
  writeConfiguredMcpSidecar(support)
  t.after(() => fs.rmSync(root, { recursive: true, force: true, maxRetries: 20, retryDelay: 10 }))
  const fixture = await startAgentd(t, 'oauth-complete-after-timeout', {
    MECHANICIAN_SUPPORT_DIR: support,
    MECHANICIAN_CODEX_MCP_OAUTH_HOLD_MS: '250',
    CODEX_FIXTURE_OAUTH_COMPLETION_DELAY_MS: '650',
  })
  const authorizationId = 'late-timed-out-oauth'
  const attemptId = `${authorizationId}-attempt`

  send(fixture.child, exactConfiguredMcpControl('mcp_authorize', authorizationId))
  await waitFor(
    () => fixture.events.find((event) => event.type === 'mcp_authorize_url'
      && event.id === authorizationId),
    'late-timeout Codex MCP authorization URL', fixture,
  )
  const timeout = await waitFor(
    () => fixture.events.find((event) => event.type === 'mcp_authorize_error'
      && event.id === authorizationId),
    'Codex MCP authorization timeout', fixture,
  )
  assert.match(timeout.message, /timed out/i)
  assert.deepEqual({
    name: timeout.name, changeId: timeout.changeId, source: timeout.source,
    serverId: timeout.serverId, accountInstanceId: timeout.accountInstanceId,
    routeIdentity: timeout.routeIdentity, operation: timeout.operation,
  }, {
    name: 'fixture-server', changeId: attemptId, source: 'configured',
    serverId: configuredMcpServerId, accountInstanceId: mcpAccountInstanceId,
    routeIdentity: codexMcpRouteIdentity, operation: 'authorize',
  })

  const ready = await waitFor(
    () => fixture.events.find((event) => event.type === 'mcp_credentials_changed'
      && event.changeId === attemptId && event.activation === 'ready'),
    'late timed-out OAuth ready event', fixture,
  )
  assert.deepEqual({
    name: ready.name, changeId: ready.changeId, source: ready.source,
    serverId: ready.serverId, accountInstanceId: ready.accountInstanceId,
    routeIdentity: ready.routeIdentity, operation: ready.operation,
    status: ready.status, tools: ready.tools,
  }, {
    name: 'fixture-server', changeId: attemptId, source: 'configured',
    serverId: configuredMcpServerId, accountInstanceId: mcpAccountInstanceId,
    routeIdentity: codexMcpRouteIdentity, operation: 'authorize',
    status: 'connected', tools: 1,
  })
  assert.deepEqual(readCodexMcpCredentialMarker(fixture), {
    schemaVersion: 1,
    revision: attemptId,
    servers: { [configuredMcpServerId]: attemptId },
  })
})

for (const replacementType of ['mcp_authorize', 'mcp_reconcile']) {
  test(`${replacementType} cannot steal attribution from a cancelled Codex browser flow`, async (t) => {
    const root = fs.mkdtempSync(path.join(
      os.tmpdir(), `mechanician-codex-oauth-cancel-replacement-${replacementType}-`))
    const support = path.join(root, 'support')
    const loginLog = path.join(root, 'oauth-logins.ndjson')
    writeConfiguredMcpSidecar(support)
    t.after(() => fs.rmSync(
      root, { recursive: true, force: true, maxRetries: 20, retryDelay: 10 }))
    const fixture = await startAgentd(t, 'oauth-complete-after-cancel', {
      MECHANICIAN_SUPPORT_DIR: support,
      CODEX_FIXTURE_MCP_OAUTH_LOGIN_FILE: loginLog,
      CODEX_FIXTURE_OAUTH_COMPLETION_DELAY_MS: '650',
    })
    const attemptA = 'cancelled-owner-a-attempt'
    const attemptB = 'replacement-owner-b-attempt'

    send(fixture.child, exactConfiguredMcpControl('mcp_authorize', 'cancelled-owner-a', {
      attemptId: attemptA,
    }))
    await waitFor(
      () => fixture.events.find((event) => event.type === 'mcp_authorize_url'
        && event.id === 'cancelled-owner-a'),
      'cancelled owner A URL', fixture,
    )
    send(fixture.child, exactConfiguredMcpControl(
      'mcp_authorize_cancel', 'cancel-owner-a', { attemptId: attemptA }))
    await waitFor(
      () => fixture.events.find((event) => event.type === 'mcp_authorize_cancel_ok'
        && event.id === 'cancel-owner-a'),
      'cancelled owner A acknowledgement', fixture,
    )

    send(fixture.child, exactConfiguredMcpControl(replacementType, 'replacement-owner-b', {
      attemptId: attemptB,
    }))
    const replacement = await waitFor(
      () => fixture.events.find((event) => event.id === 'replacement-owner-b'
        && ['mcp_authorize_error', 'mcp_reconcile_error'].includes(event.type)),
      'replacement owner B rejection', fixture,
    )
    assert.equal(replacement.changeId ?? replacement.attemptId, attemptB)
    assert.match(replacement.message, /previous authorization|still finish|still in progress/i)
    assert.equal(fs.readFileSync(loginLog, 'utf8').trim().split('\n').filter(Boolean).length, 1,
      'replacement B must not start another provider browser flow')

    const readyA = await waitFor(
      () => fixture.events.find((event) => event.type === 'mcp_credentials_changed'
        && event.changeId === attemptA && event.activation === 'ready'),
      'cancelled owner A late completion', fixture,
    )
    assert.equal(readyA.tools, 1)
    assert.equal(fixture.events.some((event) => event.type === 'mcp_credentials_changed'
      && event.changeId === attemptB), false)
    assert.deepEqual(readCodexMcpCredentialMarker(fixture), {
      schemaVersion: 1,
      revision: attemptA,
      servers: { [configuredMcpServerId]: attemptA },
    })
  })
}

for (const retirement of ['cancelled', 'timed-out']) {
  test(`${retirement} Codex OAuth can retry the exact saved attempt only after process replacement`, async (t) => {
    const root = fs.mkdtempSync(path.join(os.tmpdir(), `mechanician-codex-${retirement}-retry-`))
    const support = path.join(root, 'support')
    const starts = path.join(root, 'starts.ndjson')
    const pidFile = path.join(root, 'codex.pid')
    const logins = path.join(root, 'oauth-logins.ndjson')
    const attemptId = `${retirement}-exact-attempt-a`
    writePendingCodexAuthorization(support, attemptId)
    t.after(() => fs.rmSync(root, {
      recursive: true, force: true, maxRetries: 20, retryDelay: 10,
    }))
    const fixture = await startAgentd(t, 'retry-success', {
      MECHANICIAN_SUPPORT_DIR: support,
      CODEX_FIXTURE_START_FILE: starts,
      CODEX_FIXTURE_PID_FILE: pidFile,
      CODEX_FIXTURE_MCP_OAUTH_LOGIN_FILE: logins,
      ...(retirement === 'timed-out'
        ? { MECHANICIAN_CODEX_MCP_OAUTH_HOLD_MS: '250' } : {}),
    })
    const firstPid = Number(fs.readFileSync(pidFile, 'utf8'))

    send(fixture.child, exactConfiguredMcpControl('mcp_authorize', 'initial-exact-a', {
      attemptId,
    }))
    await waitFor(
      () => fixture.events.find((event) => event.type === 'mcp_authorize_url'
        && event.id === 'initial-exact-a'),
      `${retirement} initial OAuth URL`, fixture,
    )
    if (retirement === 'cancelled') {
      send(fixture.child, exactConfiguredMcpControl(
        'mcp_authorize_cancel', 'cancel-exact-a', { attemptId }))
      await waitFor(
        () => fixture.events.find((event) => event.type === 'mcp_authorize_cancel_ok'
          && event.id === 'cancel-exact-a'),
        'exact A cancellation', fixture,
      )
    } else {
      const timeout = await waitFor(
        () => fixture.events.find((event) => event.type === 'mcp_authorize_error'
          && event.id === 'initial-exact-a'),
        'exact A timeout', fixture,
      )
      assert.match(timeout.message, /timed out/i)
    }

    const attemptB = `${retirement}-different-attempt-b`
    send(fixture.child, exactConfiguredMcpControl('mcp_reconcile', 'reject-different-b', {
      attemptId: attemptB, resumeIfNeeded: true,
    }))
    const rejectedB = await waitFor(
      () => fixture.events.find((event) => event.type === 'mcp_reconcile_error'
        && event.id === 'reject-different-b'),
      'different retry B rejection', fixture,
    )
    assert.match(rejectedB.message, /previous authorization|exact saved attempt/i)
    assert.equal(fs.readFileSync(starts, 'utf8').trim().split('\n').length, 1)
    assert.equal(fs.readFileSync(logins, 'utf8').trim().split('\n').length, 1)

    send(fixture.child, exactConfiguredMcpControl('mcp_reconcile', 'retry-exact-a', {
      attemptId, resumeIfNeeded: true,
    }))
    const retryURL = await waitFor(
      () => fixture.events.find((event) => event.type === 'mcp_authorize_url'
        && event.id === 'retry-exact-a'),
      'same exact A retry URL', fixture, 30_000,
    )
    assert.equal(retryURL.attemptId, attemptId)
    assert.equal(retryURL.changeId, attemptId)
    assert.equal(retryURL.source, 'configured')
    assert.equal(retryURL.serverId, configuredMcpServerId)
    assert.equal(retryURL.accountInstanceId, mcpAccountInstanceId)
    assert.equal(retryURL.routeIdentity, codexMcpRouteIdentity)
    assert.equal(retryURL.operation, 'authorize')

    const startPids = fs.readFileSync(starts, 'utf8').trim().split('\n').map(Number)
    const loginEvents = fs.readFileSync(logins, 'utf8').trim().split('\n').map(JSON.parse)
    assert.equal(startPids.length, 2, 'the retry must start exactly one replacement App Server')
    assert.equal(loginEvents.length, 2)
    assert.equal(loginEvents[0].pid, firstPid)
    assert.equal(loginEvents[1].pid, startPids[1])
    assert.notEqual(loginEvents[1].pid, firstPid)
    assert.equal(loginEvents[1].processOrdinal, 2)
    await waitFor(() => {
      try { process.kill(firstPid, 0); return false } catch { return true }
    }, 'old OAuth-owning App Server exit', fixture, 2_000)
    assert.equal(fixture.events.some((event) => event.type === 'mcp_credentials_changed'
      && event.changeId === attemptB), false)
  })
}

test('an ordinary turn accepted behind an OAuth retry waits for the replacement process', async (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'mechanician-codex-retry-turn-barrier-'))
  const support = path.join(root, 'support')
  const starts = path.join(root, 'starts.ndjson')
  const logins = path.join(root, 'oauth-logins.ndjson')
  const activeTurnRelease = path.join(root, 'release-active-turn')
  const turnLog = path.join(root, 'turns.ndjson')
  const threadProcesses = path.join(root, 'thread-processes.ndjson')
  const attemptId = 'retry-turn-barrier-attempt-a'
  writePendingCodexAuthorization(support, attemptId)
  t.after(() => fs.rmSync(root, {
    recursive: true, force: true, maxRetries: 20, retryDelay: 10,
  }))
  const fixture = await startAgentd(t, 'oauth-retry-while-turn-active', {
    MECHANICIAN_SUPPORT_DIR: support,
    CODEX_FIXTURE_START_FILE: starts,
    CODEX_FIXTURE_MCP_OAUTH_LOGIN_FILE: logins,
    CODEX_FIXTURE_ACTIVE_AUTH_RELEASE_FILE: activeTurnRelease,
    CODEX_FIXTURE_TURN_FILE: turnLog,
    CODEX_FIXTURE_THREAD_PROCESS_FILE: threadProcesses,
  })
  const firstPid = Number(fs.readFileSync(starts, 'utf8').trim())

  send(fixture.child, {
    type: 'send', id: 'leased-turn-before-oauth-retry',
    convId: 'conv-leased-turn-before-oauth-retry',
    prompt: 'Hold this old-process lease.', model: 'gpt-fixture',
  })
  await waitFor(() => fs.existsSync(turnLog), 'leased old-process turn', fixture)

  send(fixture.child, exactConfiguredMcpControl('mcp_authorize', 'retry-barrier-initial', {
    attemptId,
  }))
  await waitFor(
    () => fixture.events.find((event) => event.type === 'mcp_authorize_url'
      && event.id === 'retry-barrier-initial'),
    'initial OAuth URL before retry barrier', fixture,
  )
  send(fixture.child, exactConfiguredMcpControl(
    'mcp_authorize_cancel', 'retry-barrier-cancel', { attemptId }))
  await waitFor(
    () => fixture.events.find((event) => event.type === 'mcp_authorize_cancel_ok'
      && event.id === 'retry-barrier-cancel'),
    'cancelled OAuth before retry barrier', fixture,
  )

  send(fixture.child, exactConfiguredMcpControl('mcp_reconcile', 'retry-barrier-request', {
    attemptId, resumeIfNeeded: true,
  }))
  send(fixture.child, {
    type: 'send', id: 'turn-behind-oauth-retry', convId: 'conv-turn-behind-oauth-retry',
    prompt: 'Run only after the replacement process is ready.', model: 'gpt-fixture',
  })
  await waitFor(
    () => fixture.events.find((event) => event.type === 'turn_started'
      && event.id === 'turn-behind-oauth-retry'),
    'ordinary turn accepted behind retry', fixture,
  )
  await delay(75)
  const preReleaseThreads = fs.readFileSync(threadProcesses, 'utf8')
    .trim().split('\n').filter(Boolean).map(JSON.parse)
  assert.equal(preReleaseThreads.length, 1,
    'only the already-leased turn may have opened a thread on the old process')
  assert.equal(preReleaseThreads[0].pid, firstPid)
  assert.equal(fixture.events.some((event) => event.id === 'turn-behind-oauth-retry'
    && ['done', 'error'].includes(event.type)), false)
  assert.equal(fixture.events.some((event) => event.type === 'mcp_authorize_url'
    && event.id === 'retry-barrier-request'), false)

  send(fixture.child, {
    type: 'interrupt', id: 'release-old-process-lease',
    turnId: 'leased-turn-before-oauth-retry',
  })
  await waitFor(
    () => fixture.events.find((event) => event.id === 'leased-turn-before-oauth-retry'
      && ['done', 'error'].includes(event.type)),
    'old-process leased turn terminal', fixture,
  )
  const retryURL = await waitFor(
    () => fixture.events.find((event) => event.type === 'mcp_authorize_url'
      && event.id === 'retry-barrier-request'),
    'retried OAuth URL after replacement', fixture, 30_000,
  )
  assert.equal(retryURL.changeId, attemptId)
  const terminal = await waitFor(
    () => fixture.events.find((event) => event.id === 'turn-behind-oauth-retry'
      && ['done', 'error'].includes(event.type)),
    'ordinary turn behind OAuth retry', fixture, 30_000,
  )
  assert.deepEqual(terminal, { type: 'done', id: 'turn-behind-oauth-retry' })

  const startPids = fs.readFileSync(starts, 'utf8').trim().split('\n').map(Number)
  const threadStarts = fs.readFileSync(threadProcesses, 'utf8').trim().split('\n').map(JSON.parse)
  assert.equal(startPids.length, 2)
  assert.equal(threadStarts.length, 2)
  assert.equal(threadStarts[1].pid, startPids[1])
  assert.equal(threadStarts[1].processOrdinal, 2)
  assert.notEqual(threadStarts[1].pid, firstPid)
})

for (const operation of ['authorize', 'reauthorize']) {
  test(`OAuth completion queued before captured ${operation} retry converges one exact flow`, async (t) => {
    const root = fs.mkdtempSync(path.join(
      os.tmpdir(), `mechanician-codex-oauth-first-${operation}-retry-`))
    const support = path.join(root, 'support')
    const activeTurnRelease = path.join(root, 'release-active-turn')
    const turnLog = path.join(root, 'turns.ndjson')
    const loginLog = path.join(root, 'oauth-logins.ndjson')
    const starts = path.join(root, 'starts.ndjson')
    const completionHeld = path.join(root, 'oauth-completion-held')
    const releaseCompletion = path.join(root, 'release-oauth-completion')
    const attemptId = `oauth-first-${operation}-attempt-a`
    writePendingCodexAuthorizationAndReadiness(support, attemptId, operation)
    t.after(() => fs.rmSync(root, {
      recursive: true, force: true, maxRetries: 20, retryDelay: 10,
    }))
    const fixture = await startAgentd(t, 'oauth-complete-while-turn-active', {
      MECHANICIAN_SUPPORT_DIR: support,
      CODEX_FIXTURE_ACTIVE_AUTH_RELEASE_FILE: activeTurnRelease,
      CODEX_FIXTURE_TURN_FILE: turnLog,
      CODEX_FIXTURE_MCP_OAUTH_LOGIN_FILE: loginLog,
      CODEX_FIXTURE_START_FILE: starts,
      MECHANICIAN_TEST_CODEX_OAUTH_COMPLETION_HOLD_FILE: completionHeld,
      MECHANICIAN_TEST_CODEX_OAUTH_COMPLETION_RELEASE_FILE: releaseCompletion,
    })

    send(fixture.child, {
      type: 'send', id: `leased-turn-before-${operation}-race`,
      convId: `conv-leased-turn-before-${operation}-race`,
      prompt: 'Hold the old process boundary.', model: 'gpt-fixture',
    })
    await waitFor(() => fs.existsSync(turnLog), `leased turn before ${operation} race`, fixture)
    send(fixture.child, exactConfiguredMcpControl(
      operation === 'reauthorize' ? 'mcp_reauthorize' : 'mcp_authorize',
      `${operation}-race-oauth`, { attemptId, operation }))
    await waitFor(
      () => fixture.events.find((event) => event.type === 'mcp_authorize_url'
        && event.id === `${operation}-race-oauth`),
      `${operation} race OAuth URL`, fixture,
    )
    send(fixture.child, exactConfiguredMcpControl(
      'mcp_authorize_cancel', `${operation}-race-cancel`, { attemptId, operation }))
    await waitFor(
      () => fixture.events.find((event) => event.type === 'mcp_authorize_cancel_ok'
        && event.id === `${operation}-race-cancel`),
      `${operation} race cancellation`, fixture,
    )
    await waitFor(() => fs.existsSync(completionHeld),
      `${operation} recursive OAuth completion hold`, fixture)
    assert.equal(fs.readFileSync(completionHeld, 'utf8'), '1')

    send(fixture.child, exactConfiguredMcpControl(
      'mcp_reconcile', `${operation}-race-reconcile`, {
        attemptId, operation, resumeIfNeeded: true,
      }))
    await waitFor(
      () => fixture.stderr.includes('MCP generation 2 requested:'),
      `${operation} second generation queue`, fixture,
    )
    assert.equal(fs.readFileSync(loginLog, 'utf8').trim().split('\n').filter(Boolean).length, 1)
    assert.equal(fixture.events.some((event) => event.type === 'mcp_authorize_url'
      && event.id === `${operation}-race-reconcile`), false)
    assert.equal(fixture.events.some((event) => event.id === `${operation}-race-reconcile`
      && ['mcp_reconcile_ok', 'mcp_reconcile_error'].includes(event.type)), false)

    fs.writeFileSync(releaseCompletion, 'released')
    send(fixture.child, {
      type: 'interrupt', id: `${operation}-race-release-lease`,
      turnId: `leased-turn-before-${operation}-race`,
    })
    await waitFor(
      () => fixture.events.find((event) => event.id === `leased-turn-before-${operation}-race`
        && ['done', 'error'].includes(event.type)),
      `${operation} old lease terminal`, fixture,
    )
    const oauthReady = await waitFor(
      () => fixture.events.find((event) => event.type === 'mcp_credentials_changed'
        && event.changeId === attemptId && event.activation === 'ready'),
      `${operation} OAuth ready`, fixture, 30_000,
    )
    const reconcile = await waitFor(
      () => fixture.events.find((event) => event.type === 'mcp_reconcile_ok'
        && event.id === `${operation}-race-reconcile`),
      `${operation} observation reconcile`, fixture, 30_000,
    )
    assert.ok(fixture.events.indexOf(reconcile) > fixture.events.indexOf(oauthReady))
    assert.equal(reconcile.attemptId, attemptId)
    assert.equal(reconcile.operation, operation)
    const readyEvents = fixture.events.filter((event) =>
      event.type === 'mcp_credentials_changed'
        && event.changeId === attemptId && event.activation === 'ready')
    assert.equal(readyEvents.length, 2,
      'OAuth and observation reconcile each publish exact readiness for attempt A')
    assert.equal(readyEvents[1].status, 'connected')
    assert.equal(readyEvents[1].tools, 1)
    assert.ok(fixture.events.indexOf(reconcile) > fixture.events.indexOf(readyEvents[1]))
    assert.equal(fixture.events.some((event) => event.type === 'mcp_reconcile_error'
      && event.id === `${operation}-race-reconcile`), false)
    assert.equal(fixture.events.some((event) => event.type === 'mcp_authorize_url'
      && event.id === `${operation}-race-reconcile`), false)
    assert.equal(fs.readFileSync(loginLog, 'utf8').trim().split('\n').filter(Boolean).length, 1)
    assert.equal(fs.readFileSync(starts, 'utf8').trim().split('\n').filter(Boolean).length, 1)
    assert.deepEqual(readCodexMcpCredentialMarker(fixture), {
      schemaVersion: 1,
      revision: attemptId,
      servers: { [configuredMcpServerId]: attemptId },
    })
  })
}

test('configured Codex auth leaves an active turn intact and gates the next send on fresh tools', async (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'mechanician-codex-auth-active-turn-'))
  const support = path.join(root, 'support')
  const release = path.join(root, 'release-active-turn')
  const turnLog = path.join(root, 'turns.ndjson')
  const startLog = path.join(root, 'thread-starts.ndjson')
  const resumeLog = path.join(root, 'thread-resumes.ndjson')
  writeConfiguredMcpSidecar(support)
  t.after(() => fs.rmSync(root, { recursive: true, force: true, maxRetries: 20, retryDelay: 10 }))
  const fixture = await startAgentd(t, 'oauth-complete-while-turn-active', {
    MECHANICIAN_SUPPORT_DIR: support,
    CODEX_FIXTURE_ACTIVE_AUTH_RELEASE_FILE: release,
    CODEX_FIXTURE_TURN_FILE: turnLog,
    CODEX_FIXTURE_THREAD_START_LOG_FILE: startLog,
    CODEX_FIXTURE_RESUME_LOG_FILE: resumeLog,
  })
  const activeTurnId = 'turn-active-before-mcp-auth'
  const oldSession = 'codex-tools:thread-before-mcp-auth'

  send(fixture.child, {
    type: 'send', id: activeTurnId, convId: `conv-${activeTurnId}`,
    prompt: 'Keep this already-running turn intact.', model: 'gpt-fixture',
    sessionId: oldSession,
  })
  await waitFor(() => fs.existsSync(turnLog), 'active pre-auth Codex turn', fixture)

  const authorizationId = 'authorize-during-active-codex-turn'
  const changeId = `${authorizationId}-attempt`
  send(fixture.child, exactConfiguredMcpControl('mcp_authorize', authorizationId))
  await waitFor(
    () => fixture.events.find((event) => event.type === 'mcp_authorize_url'
      && event.id === authorizationId),
    'active-turn Codex authorization URL', fixture,
  )
  await waitFor(
    () => fixture.events.find((event) => event.type === 'mcp_credentials_changed'
      && event.changeId === changeId && event.activation === 'activating'),
    'active-turn Codex credential mutation', fixture,
  )
  await delay(100)
  assert.equal(fixture.events.some((event) => event.id === activeTurnId
    && ['done', 'error'].includes(event.type)), false,
  'credential publication must not interrupt or replace the already-running provider turn')
  assert.equal(fixture.events.some((event) => event.type === 'mcp_credentials_changed'
    && event.changeId === changeId && event.activation === 'ready'), false,
  'activation waits for the running turn to release its exact provider process')

  send(fixture.child, { type: 'interrupt', id: 'release-active-codex-turn', turnId: activeTurnId })
  const activeTerminal = await waitFor(
    () => fixture.events.find((event) => event.id === activeTurnId
      && ['done', 'error'].includes(event.type)),
    'active pre-auth Codex turn terminal', fixture,
  )
  assert.deepEqual(activeTerminal, { type: 'done', id: activeTurnId, interrupted: true })
  const authorization = await waitFor(
    () => fixture.events.find((event) => event.type === 'mcp_authorize_ok'
      && event.id === authorizationId),
    'active-turn Codex authorization activation', fixture, 30_000,
  )
  assert.equal(authorization.changeId, changeId)
  assert.equal(authorization.tools, 1)
  writeConfiguredCodexReadiness(support, changeId)
  const lineCount = (file) => fs.existsSync(file)
    ? fs.readFileSync(file, 'utf8').trim().split('\n').filter(Boolean).length : 0
  const startsBeforePostAuth = lineCount(startLog)
  const resumesBeforePostAuth = lineCount(resumeLog)

  const nextTurnId = 'first-turn-after-active-codex-auth'
  const nextTerminal = await runTurn(fixture, nextTurnId, {
    sessionId: oldSession,
    mcpReadinessClaims: [{
      name: 'fixture-server', changeId, source: 'configured',
      serverId: configuredMcpServerId, accountInstanceId: mcpAccountInstanceId,
      routeIdentity: codexMcpRouteIdentity,
    }],
  })
  assert.deepEqual(nextTerminal, { type: 'done', id: nextTurnId })
  assert.deepEqual(fixture.events.find((event) =>
    event.type === 'mcp_readiness_proof' && event.id === nextTurnId), {
    type: 'mcp_readiness_proof', id: nextTurnId,
    name: 'fixture-server', changeId, source: 'configured',
    serverId: configuredMcpServerId, accountInstanceId: mcpAccountInstanceId,
    routeIdentity: codexMcpRouteIdentity, status: 'connected', tools: 1,
  })
  assert.equal(lineCount(resumeLog), resumesBeforePostAuth,
    'the first post-auth turn must not resume the old app-supplied provider thread')
  assert.equal(lineCount(startLog), startsBeforePostAuth + 1,
    'the first post-auth turn must mint a fresh provider thread after exact readiness proof')
})

test('malformed account reload identity neither reloads credentials nor rotates MCP ownership', async (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'mechanician-codex-account-malformed-'))
  const support = path.join(root, 'support')
  const accountReads = path.join(root, 'account-reads.ndjson')
  fs.mkdirSync(support, { recursive: true })
  fs.writeFileSync(path.join(support, 'extensions.json'), JSON.stringify({ mcpServers: [] }))
  t.after(() => fs.rmSync(root, { recursive: true, force: true, maxRetries: 20, retryDelay: 10 }))
  const fixture = await startAgentd(t, 'retry-success', {
    MECHANICIAN_SUPPORT_DIR: support,
    CODEX_FIXTURE_ACCOUNT_READ_FILE: accountReads,
  })
  const readyCount = fixture.events.filter((event) => event.type === 'ready').length

  send(fixture.child, {
    type: 'account_reload', id: 'malformed-account-reload',
    accountInstanceId: 'not-a-provider-account-id',
  })
  const rejection = await waitFor(
    () => fixture.events.find((event) =>
      event.type === 'login_error' && event.id === 'malformed-account-reload'),
    'malformed account reload rejection', fixture,
  )

  assert.match(rejection.message, /identity is invalid/i)
  await delay(100)
  assert.equal(fs.readFileSync(accountReads, 'utf8').trim().split('\n').length, 1)
  assert.equal(fixture.events.filter((event) => event.type === 'ready').length, readyCount)
  assert.equal(fixture.events.filter((event) => event.type === 'ready').at(-1)
    .accountInstanceId, mcpAccountInstanceId)
  assert.equal(fixture.events.some((event) =>
    event.type === 'account_reload_ok' && event.id === 'malformed-account-reload'), false)
})

test('failed account credential reload preserves the prior MCP account identity', async (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'mechanician-codex-account-failed-'))
  const support = path.join(root, 'support')
  const accountReads = path.join(root, 'account-reads.ndjson')
  fs.mkdirSync(support, { recursive: true })
  fs.writeFileSync(path.join(support, 'extensions.json'), JSON.stringify({ mcpServers: [] }))
  t.after(() => fs.rmSync(root, { recursive: true, force: true, maxRetries: 20, retryDelay: 10 }))
  const fixture = await startAgentd(t, 'account-reload-read-failure', {
    MECHANICIAN_SUPPORT_DIR: support,
    CODEX_FIXTURE_ACCOUNT_READ_FILE: accountReads,
  })
  const readsBeforeReload = fs.readFileSync(accountReads, 'utf8')
    .trim().split('\n').filter(Boolean).length

  send(fixture.child, {
    type: 'account_reload', id: 'failed-account-reload',
    accountInstanceId: replacementMcpAccountInstanceId,
  })
  const failure = await waitFor(
    () => fixture.events.find((event) =>
      event.type === 'login_error' && event.id === 'failed-account-reload'),
    'failed account credential reload', fixture,
  )
  assert.match(failure.message, /fixture account reload failed/i)
  const readsAfterFailure = fs.readFileSync(accountReads, 'utf8')
    .trim().split('\n').filter(Boolean).length
  assert.ok(readsAfterFailure > readsBeforeReload,
    'the explicit reload must consult the replacement process account')
  assert.equal(fixture.events.some((event) => event.type === 'ready'
    && event.accountInstanceId === replacementMcpAccountInstanceId.toLowerCase()), false)
  assert.equal(fixture.events.some((event) =>
    event.type === 'account_reload_ok' && event.id === 'failed-account-reload'), false)

  const terminal = await runTurn(fixture, 'old-account-after-reload-failure', {
    mcpReadinessClaims: [{
      name: 'missing-server', changeId: 'old-account-still-owned', source: 'configured',
      serverId: configuredMcpServerId,
      accountInstanceId: mcpAccountInstanceId, routeIdentity: codexMcpRouteIdentity,
    }],
  }, ['control_error', 'error', 'done'])
  assert.equal(terminal.type, 'error')
  assert.match(terminal.message, /fixture account reload failed|generation changed/i,
    'a failed replacement remains fail-closed under the old account identity')
})

for (const race of [
  {
    label: 'before the delayed account read returns',
    mode: 'account-reload-notification-before-read',
  },
  {
    label: 'after account read while its model catalog is pending',
    mode: 'account-reload-notification-during-catalog',
  },
]) {
  test(`account reload rejects a newer account notification ${race.label}`, async (t) => {
    const root = fs.mkdtempSync(path.join(os.tmpdir(), 'mechanician-codex-account-race-'))
    const support = path.join(root, 'support')
    writeConfiguredMcpSidecar(support, [])
    t.after(() => fs.rmSync(root, {
      recursive: true, force: true, maxRetries: 20, retryDelay: 10,
    }))
    const fixture = await startAgentd(t, race.mode, { MECHANICIAN_SUPPORT_DIR: support })
    const before = fixture.events.length

    send(fixture.child, {
      type: 'account_reload', id: `account-race-${race.mode}`,
      accountInstanceId: replacementMcpAccountInstanceId,
    })
    const rejection = await waitFor(
      () => fixture.events.find((event) => event.type === 'login_error'
        && event.id === `account-race-${race.mode}`),
      `account reload race ${race.mode}`, fixture,
    )

    assert.match(rejection.message, /changed again while it was being reloaded/i)
    await delay(150)
    const raced = fixture.events.slice(before)
    assert.equal(raced.some((event) => event.type === 'account_reload_ok'
      && event.id === `account-race-${race.mode}`), false)
    assert.equal(raced.some((event) => event.type === 'ready'
      && event.accountInstanceId === replacementMcpAccountInstanceId.toLowerCase()), false)
    const notificationReady = raced.find((event) => event.type === 'ready'
      && event.accountInstanceId === mcpAccountInstanceId && event.planType === 'pro')
    assert.ok(notificationReady,
      'the newer account/updated notification must retain publication authority under the old id')
    assert.equal(fixture.child.exitCode, null)
  })
}

test('successful account reload commits lowercase identity before ready and rejects old claims', async (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'mechanician-codex-account-success-'))
  const support = path.join(root, 'support')
  const starts = path.join(root, 'starts.ndjson')
  fs.mkdirSync(support, { recursive: true })
  fs.writeFileSync(path.join(support, 'extensions.json'), JSON.stringify({ mcpServers: [] }))
  t.after(() => fs.rmSync(root, { recursive: true, force: true, maxRetries: 20, retryDelay: 10 }))
  const fixture = await startAgentd(t, 'retry-success', {
    MECHANICIAN_SUPPORT_DIR: support,
    CODEX_FIXTURE_THREAD_START_LOG_FILE: starts,
  })
  const before = fixture.events.length

  send(fixture.child, {
    type: 'account_reload', id: 'successful-account-reload',
    accountInstanceId: replacementMcpAccountInstanceId,
  })
  const completion = await waitFor(
    () => fixture.events.find((event) =>
      event.type === 'account_reload_ok' && event.id === 'successful-account-reload'),
    'successful account reload', fixture,
  )
  const postReload = fixture.events.slice(before)
  const readyIndex = postReload.findIndex((event) => event.type === 'ready'
    && event.accountInstanceId === replacementMcpAccountInstanceId.toLowerCase())
  const completionIndex = postReload.findIndex((event) =>
    event.type === 'account_reload_ok' && event.id === 'successful-account-reload')
  assert.ok(readyIndex >= 0 && completionIndex > readyIndex)
  assert.equal(completion.accountInstanceId, replacementMcpAccountInstanceId.toLowerCase())

  const oldClaim = await runTurn(fixture, 'old-account-readiness-after-reload', {
    mcpReadinessClaims: [{
      name: 'missing-server', changeId: 'old-account-claim', source: 'configured',
      serverId: configuredMcpServerId,
      accountInstanceId: mcpAccountInstanceId, routeIdentity: codexMcpRouteIdentity,
    }],
  }, ['control_error', 'error', 'done'])
  assert.equal(oldClaim.type, 'control_error')
  assert.match(oldClaim.message, /different provider account or route/i)
  assert.equal(fs.existsSync(starts), false)

  const newClaim = await runTurn(fixture, 'new-account-readiness-after-reload', {
    mcpReadinessClaims: [{
      name: 'missing-server', changeId: 'new-account-claim', source: 'configured',
      serverId: configuredMcpServerId,
      accountInstanceId: replacementMcpAccountInstanceId.toLowerCase(),
      routeIdentity: codexMcpRouteIdentity,
    }],
  }, ['control_error', 'error', 'done'])
  assert.equal(newClaim.type, 'error')
  assert.match(newClaim.message, /generation changed/i)
})

test('account reload queued first retires its OAuth stream before a late completion can publish', async (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'mechanician-codex-account-oauth-order-'))
  const support = path.join(root, 'support')
  const starts = path.join(root, 'starts.ndjson')
  const authorizationId = 'old-account-oauth-before-reload'
  const attemptId = `${authorizationId}-attempt`
  writeConfiguredMcpSidecar(support)
  t.after(() => fs.rmSync(root, {
    recursive: true, force: true, maxRetries: 20, retryDelay: 10,
  }))
  const fixture = await startAgentd(t, 'oauth-complete-after-cancel', {
    MECHANICIAN_SUPPORT_DIR: support,
    CODEX_FIXTURE_START_FILE: starts,
    CODEX_FIXTURE_OAUTH_COMPLETION_DELAY_MS: '350',
  })

  send(fixture.child, exactConfiguredMcpControl('mcp_authorize', authorizationId))
  await waitFor(
    () => fixture.events.find((event) => event.type === 'mcp_authorize_url'
      && event.id === authorizationId),
    'old-account OAuth URL', fixture,
  )
  send(fixture.child, {
    type: 'account_reload', id: 'account-first-before-late-oauth',
    accountInstanceId: replacementMcpAccountInstanceId,
  })
  const account = await waitFor(
    () => fixture.events.find((event) => event.type === 'account_reload_ok'
      && event.id === 'account-first-before-late-oauth'),
    'account B before late OAuth completion', fixture, 30_000,
  )
  const accountIndex = fixture.events.indexOf(account)
  assert.equal(account.accountInstanceId, replacementMcpAccountInstanceId.toLowerCase())
  assert.equal(
    fs.readFileSync(starts, 'utf8').trim().split('\n').filter(Boolean).length,
    2,
    'account reload replaces the exact name-only OAuth stream once',
  )

  await delay(450)
  assert.equal(fixture.events.some((event) => event.type === 'mcp_credentials_changed'
    && event.changeId === attemptId), false)
  assert.equal(fixture.events.some((event) => event.type === 'mcp_authorize_ok'
    && event.id === authorizationId), false)
  assert.equal(fixture.events.slice(accountIndex + 1).some((event) =>
    event.type === 'mcp_credentials_changed' && event.changeId === attemptId), false)
  assert.equal(fs.existsSync(codexMcpCredentialMarkerPath(fixture)), false,
    'late OAuth A cannot write a generation marker into account B')
  assert.equal(fixture.child.exitCode, null)
})

test('account reload retires an old Codex OAuth waiter and its local readiness claim', async (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'mechanician-codex-account-mcp-retire-'))
  const support = path.join(root, 'support')
  writeConfiguredMcpSidecar(support, [
    {
      id: configuredMcpServerId,
      name: 'fixture-server', enabled: true, transport: 'stdio', command: '/bin/echo',
    },
    {
      id: secondConfiguredMcpServerId,
      name: 'fixture-server-two', enabled: true, transport: 'stdio', command: '/bin/echo',
    },
  ])
  t.after(() => fs.rmSync(root, { recursive: true, force: true, maxRetries: 20, retryDelay: 10 }))
  const fixture = await startAgentd(t, 'oauth-first-completes-second-holds', {
    MECHANICIAN_SUPPORT_DIR: support,
  })

  send(fixture.child, exactConfiguredMcpControl('mcp_authorize', 'claim-before-reload'))
  await waitFor(
    () => fixture.events.find((event) => event.type === 'mcp_authorize_ok'
      && event.id === 'claim-before-reload'),
    'pre-reload local readiness claim', fixture,
  )
  send(fixture.child, exactConfiguredMcpControl('mcp_authorize', 'waiter-before-reload', {
    name: 'fixture-server-two', serverId: secondConfiguredMcpServerId,
  }))
  await waitFor(
    () => fixture.events.find((event) => event.type === 'mcp_authorize_url'
      && event.id === 'waiter-before-reload'),
    'pre-reload OAuth waiter', fixture,
  )

  send(fixture.child, {
    type: 'account_reload', id: 'retire-mcp-account-state',
    accountInstanceId: replacementMcpAccountInstanceId,
  })
  await waitFor(
    () => fixture.events.find((event) => event.type === 'account_reload_ok'
      && event.id === 'retire-mcp-account-state'),
    'account reload retiring MCP state', fixture,
  )

  send(fixture.child, exactConfiguredMcpControl(
    'mcp_authorize_cancel', 'cancel-retired-waiter', {
      attemptId: 'waiter-before-reload-attempt',
      name: 'fixture-server-two', serverId: secondConfiguredMcpServerId,
      accountInstanceId: replacementMcpAccountInstanceId.toLowerCase(),
    }))
  await waitFor(
    () => fixture.events.find((event) => event.type === 'mcp_authorize_cancel_ok'
      && event.id === 'cancel-retired-waiter'),
    'retired OAuth waiter cancellation', fixture,
  )

  const terminal = await runTurn(fixture, 'turn-after-account-state-retirement')
  assert.equal(terminal.type, 'done')
  assert.equal(fixture.events.some((event) =>
    event.type === 'mcp_readiness_proof'
      && event.id === 'turn-after-account-state-retirement'), false)
})

test('two sequential Codex authorizations coexist until one turn proves both inventories', async (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'mechanician-codex-two-auth-claims-'))
  const support = path.join(root, 'support')
  writeConfiguredMcpSidecar(support, [
    {
      id: configuredMcpServerId,
      name: 'fixture-server', enabled: true, transport: 'stdio', command: '/bin/echo',
    },
    {
      id: secondConfiguredMcpServerId,
      name: 'fixture-server-two', enabled: true, transport: 'stdio', command: '/bin/echo',
    },
  ])
  t.after(() => fs.rmSync(root, { recursive: true, force: true, maxRetries: 20, retryDelay: 10 }))
  const fixture = await startAgentd(t, 'oauth-complete-two-servers', {
    MECHANICIAN_SUPPORT_DIR: support,
  })

  send(fixture.child, exactConfiguredMcpControl('mcp_authorize', 'authorize-first'))
  await waitFor(
    () => fixture.events.find((event) => event.type === 'mcp_authorize_ok'
      && event.id === 'authorize-first'),
    'first completed authorization', fixture,
  )
  send(fixture.child, exactConfiguredMcpControl('mcp_authorize', 'authorize-second', {
    name: 'fixture-server-two', serverId: secondConfiguredMcpServerId,
  }))
  await waitFor(
    () => fixture.events.find((event) => event.type === 'mcp_authorize_ok'
      && event.id === 'authorize-second'),
    'second completed authorization', fixture,
  )

  writeCodexReadiness(support, [
    {
      name: 'fixture-server', changeId: 'authorize-first-attempt', source: 'configured',
      serverID: configuredMcpServerId, accountInstanceID: mcpAccountInstanceId,
      routeIdentity: codexMcpRouteIdentity,
    },
    {
      name: 'fixture-server-two', changeId: 'authorize-second-attempt', source: 'configured',
      serverID: secondConfiguredMcpServerId, accountInstanceID: mcpAccountInstanceId,
      routeIdentity: codexMcpRouteIdentity,
    },
  ], [
    {
      id: configuredMcpServerId,
      name: 'fixture-server', enabled: true, transport: 'stdio', command: '/bin/echo',
    },
    {
      id: secondConfiguredMcpServerId,
      name: 'fixture-server-two', enabled: true, transport: 'stdio', command: '/bin/echo',
    },
  ])

  assert.equal(fixture.events.some((event) => event.type === 'turn_started'), false)
  const terminal = await runTurn(fixture, 'prove-two-local-claims', {
    sessionId: 'codex-tools:before-two-authorizations',
  })
  assert.equal(terminal.type, 'done')
  const proofs = fixture.events.filter((event) =>
    event.type === 'mcp_readiness_proof' && event.id === 'prove-two-local-claims')
  assert.deepEqual(proofs.map((event) => [event.name, event.changeId]), [
    ['fixture-server', 'authorize-first-attempt'],
    ['fixture-server-two', 'authorize-second-attempt'],
  ])
  assert.ok(proofs.every((event) => event.tools === 1))
})

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
    test(`${operation} for the wrong Codex ${identityCase.label} is rejected before credential access`, async (t) => {
      const root = fs.mkdtempSync(path.join(
        os.tmpdir(), `mechanician-codex-${operation}-wrong-${identityCase.label}-`))
      const support = path.join(root, 'support')
      const logout = path.join(root, 'logout.txt')
      writeConfiguredMcpSidecar(support)
      t.after(() => fs.rmSync(root, {
        recursive: true, force: true, maxRetries: 20, retryDelay: 10,
      }))
      const fixture = await startAgentd(t, 'retry-success', {
        MECHANICIAN_SUPPORT_DIR: support,
        CODEX_FIXTURE_MCP_LOGOUT_FILE: logout,
      })
      const id = `${operation}-wrong-${identityCase.label}`

      send(fixture.child, exactConfiguredMcpControl(operation, id, identityCase.override))
      const rejection = await waitFor(
        () => fixture.events.find((event) =>
          event.type === 'mcp_authorize_error' && event.id === id),
        `${operation} wrong ${identityCase.label} rejection`, fixture,
      )

      assert.match(rejection.message, /different provider account or route/i)
      assert.equal(fixture.events.some((event) =>
        event.type === 'mcp_authorize_url' && event.id === id), false)
      assert.equal(fs.existsSync(logout), false,
        'identity-mismatched clear must not invoke the provider credential command')
    })
  }
}

test('a sibling daemon converges a shared Codex OAuth generation before its next thread', async (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'mechanician-codex-shared-oauth-'))
  const sharedConfig = path.join(root, 'config')
  const sharedSupport = path.join(root, 'support')
  const siblingReload = path.join(root, 'sibling-reload.txt')
  const siblingStarts = path.join(root, 'sibling-thread-starts.ndjson')
  const siblingResumes = path.join(root, 'sibling-thread-resumes.ndjson')
  const siblingTurns = path.join(root, 'sibling-turns.ndjson')
  writeConfiguredMcpSidecar(sharedSupport)
  t.after(() => fs.rmSync(root, { recursive: true, force: true, maxRetries: 20, retryDelay: 10 }))

  const common = {
    MECHANICIAN_CONFIG_DIR: sharedConfig,
    MECHANICIAN_SUPPORT_DIR: sharedSupport,
  }
  const authorizing = await startAgentd(t, 'oauth-complete-reload', common)
  const sibling = await startAgentd(t, 'retry-success', {
    ...common,
    CODEX_FIXTURE_MCP_RELOAD_FILE: siblingReload,
    CODEX_FIXTURE_THREAD_START_LOG_FILE: siblingStarts,
    CODEX_FIXTURE_RESUME_LOG_FILE: siblingResumes,
    CODEX_FIXTURE_TURN_FILE: siblingTurns,
  })

  send(authorizing.child, exactConfiguredMcpControl('mcp_authorize', 'shared-oauth'))
  await waitFor(
    () => authorizing.events.find((event) => event.type === 'mcp_authorize_ok'
      && event.id === 'shared-oauth'),
    'shared OAuth activation', authorizing,
  )

  const terminal = await runTurn(sibling, 'shared-generation-turn', {
    prompt: 'Use the newly authorized server.',
    sessionId: 'codex-tools:pre-auth-thread',
    history: [
      { role: 'user', text: 'Earlier question.' },
      { role: 'assistant', text: 'Earlier answer.' },
      { role: 'user', text: 'Use the newly authorized server.' },
    ],
  })

  assert.equal(terminal.type, 'done')
  assert.equal(fs.existsSync(siblingReload), true,
    'the sibling reloads its process view before opening the fresh thread')
  assert.match(sibling.stderr, /cross-window MCP change before Codex turn/)
  assert.equal(fs.existsSync(siblingStarts), true,
    'the credential marker makes the pre-auth thread schema non-resumable after relaunch')
  assert.equal(fs.existsSync(siblingResumes), false)
  const providerTurn = fs.readFileSync(siblingTurns, 'utf8')
    .trim().split('\n').map(JSON.parse).at(-1)
  assert.match(providerTurn.input[0].text, /Earlier question\./)
  assert.match(providerTurn.input[0].text, /Earlier answer\./)
})

test('a Codex readiness claim proves exact tool inventory before starting a fresh thread', async (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'mechanician-codex-turn-proof-'))
  const support = path.join(root, 'support')
  const starts = path.join(root, 'starts.ndjson')
  const resumes = path.join(root, 'resumes.ndjson')
  fs.mkdirSync(support, { recursive: true })
  fs.writeFileSync(path.join(support, 'extensions.json'), JSON.stringify({
    mcpServers: [{
      id: '7f661a72-4885-42ad-bce1-242b6741d88a',
      name: 'fixture-server', command: '/bin/echo',
    }],
  }))
  t.after(() => fs.rmSync(root, { recursive: true, force: true, maxRetries: 20, retryDelay: 10 }))
  const fixture = await startAgentd(t, 'retry-success', {
    MECHANICIAN_SUPPORT_DIR: support,
    CODEX_FIXTURE_THREAD_START_LOG_FILE: starts,
    CODEX_FIXTURE_RESUME_LOG_FILE: resumes,
  })
  writeCodexMcpCredentialMarker(fixture, 'credential-change-1')
  writeConfiguredCodexReadiness(support, 'credential-change-1')

  const terminal = await runTurn(fixture, 'exact-mcp-proof', {
    sessionId: 'codex-tools:pre-auth-thread',
    mcpReadinessClaims: [{
      name: 'fixture-server', changeId: 'credential-change-1', source: 'configured',
      serverId: '7f661a72-4885-42ad-bce1-242b6741d88a',
      accountInstanceId: mcpAccountInstanceId,
      routeIdentity: codexMcpRouteIdentity,
    }],
    history: [
      { role: 'user', text: 'Before auth.' },
      { role: 'assistant', text: 'Waiting.' },
      { role: 'user', text: 'Use it now.' },
    ],
  })

  assert.deepEqual(terminal, { type: 'done', id: 'exact-mcp-proof' })
  const proofIndex = fixture.events.findIndex((event) =>
    event.type === 'mcp_readiness_proof' && event.id === 'exact-mcp-proof')
  const sessionIndex = fixture.events.findIndex((event) =>
    event.type === 'session' && event.id === 'exact-mcp-proof')
  assert.ok(proofIndex >= 0 && sessionIndex > proofIndex)
  assert.deepEqual(fixture.events[proofIndex], {
    type: 'mcp_readiness_proof', id: 'exact-mcp-proof',
    name: 'fixture-server', changeId: 'credential-change-1',
    source: 'configured',
    serverId: '7f661a72-4885-42ad-bce1-242b6741d88a',
    accountInstanceId: mcpAccountInstanceId,
    routeIdentity: codexMcpRouteIdentity,
    status: 'connected', tools: 1,
  })
  assert.equal(fs.existsSync(starts), true)
  assert.equal(fs.existsSync(resumes), false)
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
  test(`a Codex readiness claim for the wrong ${identityCase.label} is rejected before thread start`, async (t) => {
    const root = fs.mkdtempSync(path.join(os.tmpdir(), `mechanician-codex-wrong-${identityCase.label}-`))
    const support = path.join(root, 'support')
    const starts = path.join(root, 'starts.ndjson')
    fs.mkdirSync(support, { recursive: true })
    fs.writeFileSync(path.join(support, 'extensions.json'), JSON.stringify({
      mcpServers: [{
        id: '7f661a72-4885-42ad-bce1-242b6741d88a',
        name: 'fixture-server', command: '/bin/echo',
      }],
    }))
    t.after(() => fs.rmSync(root, {
      recursive: true, force: true, maxRetries: 20, retryDelay: 10,
    }))
    const fixture = await startAgentd(t, 'retry-success', {
      MECHANICIAN_SUPPORT_DIR: support,
      CODEX_FIXTURE_THREAD_START_LOG_FILE: starts,
    })
    const id = `wrong-${identityCase.label}-mcp-proof`

    const terminal = await runTurn(fixture, id, {
      sessionId: 'codex-tools:pre-auth-thread',
      mcpReadinessClaims: [{
        name: 'fixture-server', changeId: `wrong-${identityCase.label}-generation`,
        source: 'configured',
        serverId: '7f661a72-4885-42ad-bce1-242b6741d88a',
        accountInstanceId: mcpAccountInstanceId,
        routeIdentity: codexMcpRouteIdentity,
        ...identityCase.override,
      }],
    }, ['control_error', 'done', 'error'])

    assert.equal(terminal.type, 'control_error')
    assert.match(terminal.message, new RegExp(identityCase.label, 'i'))
    assert.equal(fs.existsSync(starts), false)
    assert.equal(fixture.events.some((event) =>
      event.type === 'mcp_readiness_proof' && event.id === id), false)
    assert.equal(fixture.events.some((event) =>
      event.type === 'session' && event.id === id), false)
  })
}

test('a Codex readiness claim absent from prepared configuration fails before thread start', async (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'mechanician-codex-missing-claim-'))
  const starts = path.join(root, 'starts.ndjson')
  t.after(() => fs.rmSync(root, { recursive: true, force: true, maxRetries: 20, retryDelay: 10 }))
  const support = path.join(root, 'support')
  writeCodexReadiness(support, [{
    name: 'missing-server', changeId: 'credential-change-2', source: 'configured',
    serverID: 'e65b4b19-4cf3-4f45-b65d-4536bf6bf023',
    accountInstanceID: mcpAccountInstanceId, routeIdentity: codexMcpRouteIdentity,
  }], [])
  const fixture = await startAgentd(t, 'retry-success', {
    MECHANICIAN_SUPPORT_DIR: support,
    CODEX_FIXTURE_THREAD_START_LOG_FILE: starts,
  })
  writeCodexMcpCredentialMarker(
    fixture, 'credential-change-2', 'e65b4b19-4cf3-4f45-b65d-4536bf6bf023')

  const terminal = await runTurn(fixture, 'missing-mcp-proof', {
    sessionId: 'codex-tools:pre-auth-thread',
    mcpReadinessClaims: [{
      name: 'missing-server', changeId: 'credential-change-2', source: 'configured',
      serverId: 'e65b4b19-4cf3-4f45-b65d-4536bf6bf023',
      accountInstanceId: 'a1faed81-8eba-4242-97fa-b3a5d9212585',
      routeIdentity: 'codex:subscription:builtin',
    }],
  })

  assert.equal(terminal.type, 'error')
  assert.match(terminal.message, /absent from this provider configuration/i)
  assert.equal(fs.existsSync(starts), false)
  assert.equal(fixture.events.some((event) =>
    event.type === 'mcp_readiness_proof' && event.id === 'missing-mcp-proof'), false)
})

for (const markerCase of [
  { label: 'missing', write: false },
  { label: 'stale', write: true },
]) {
  test(`a Codex readiness claim with a ${markerCase.label} credential generation fails before thread start`, async (t) => {
    const root = fs.mkdtempSync(path.join(
      os.tmpdir(), `mechanician-codex-${markerCase.label}-generation-`))
    const support = path.join(root, 'support')
    const starts = path.join(root, 'starts.ndjson')
    writeConfiguredMcpSidecar(support)
    t.after(() => fs.rmSync(root, {
      recursive: true, force: true, maxRetries: 20, retryDelay: 10,
    }))
    const fixture = await startAgentd(t, 'retry-success', {
      MECHANICIAN_SUPPORT_DIR: support,
      CODEX_FIXTURE_THREAD_START_LOG_FILE: starts,
    })
    writeConfiguredCodexReadiness(support, 'credential-generation-after-auth')
    if (markerCase.write) {
      writeCodexMcpCredentialMarker(fixture, 'credential-generation-before-auth')
    }
    const id = `${markerCase.label}-credential-generation`

    const terminal = await runTurn(fixture, id, {
      sessionId: 'codex-tools:pre-auth-thread',
      mcpReadinessClaims: [{
        name: 'fixture-server', changeId: 'credential-generation-after-auth',
        source: 'configured', serverId: configuredMcpServerId,
        accountInstanceId: mcpAccountInstanceId,
        routeIdentity: codexMcpRouteIdentity,
      }],
    })

    assert.equal(terminal.type, 'error')
    assert.match(terminal.message, /credential generation changed/i)
    assert.equal(fs.existsSync(starts), false)
    assert.equal(fixture.events.some((event) =>
      event.type === 'mcp_readiness_proof' && event.id === id), false)
    assert.equal(fixture.events.some((event) =>
      event.type === 'session' && event.id === id), false)
  })
}

test('Codex reconciliation never replaces a different durable credential generation', async (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'mechanician-codex-reconcile-stale-'))
  const support = path.join(root, 'support')
  const observations = path.join(root, 'status-observations.ndjson')
  writeConfiguredMcpSidecar(support)
  t.after(() => fs.rmSync(root, { recursive: true, force: true, maxRetries: 20, retryDelay: 10 }))
  const fixture = await startAgentd(t, 'retry-success', {
    MECHANICIAN_SUPPORT_DIR: support,
    CODEX_FIXTURE_MCP_STATUS_OBSERVATION_FILE: observations,
  })
  writeCodexMcpCredentialMarker(fixture, 'newer-credential-generation')
  fs.rmSync(observations, { force: true })

  const request = exactConfiguredMcpControl('mcp_reconcile', 'stale-reconcile', {
    attemptId: 'older-credential-generation', operation: 'authorize',
  })
  send(fixture.child, request)

  const terminal = await waitFor(
    () => fixture.events.find((event) =>
      event.type === 'mcp_reconcile_error' && event.id === request.id),
    'stale Codex reconciliation rejection', fixture,
  )
  assert.match(terminal.message, /newer credential change superseded/i)
  assert.deepEqual(readCodexMcpCredentialMarker(fixture), {
    schemaVersion: 1,
    revision: 'newer-credential-generation',
    servers: { [configuredMcpServerId]: 'newer-credential-generation' },
  })
  assert.equal(fs.existsSync(observations), false,
    'a stale attempt must be rejected before provider observation or marker mutation')
})

test('Codex reconciliation publishes a missing marker only after exact tool-ready evidence', async (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'mechanician-codex-reconcile-marker-'))
  const support = path.join(root, 'support')
  const observations = path.join(root, 'status-observations.ndjson')
  writeConfiguredMcpSidecar(support)
  t.after(() => fs.rmSync(root, { recursive: true, force: true, maxRetries: 20, retryDelay: 10 }))
  const fixture = await startAgentd(t, 'retry-success', {
    MECHANICIAN_SUPPORT_DIR: support,
    CODEX_FIXTURE_MCP_STATUS_OBSERVATION_FILE: observations,
  })
  fs.rmSync(observations, { force: true })
  assert.equal(fs.existsSync(codexMcpCredentialMarkerPath(fixture)), false)

  const request = exactConfiguredMcpControl('mcp_reconcile', 'missing-marker-reconcile', {
    attemptId: 'observed-credential-generation', operation: 'authorize',
  })
  send(fixture.child, request)

  const terminal = await waitFor(
    () => fixture.events.find((event) =>
      event.type === 'mcp_reconcile_ok' && event.id === request.id),
    'missing-marker Codex reconciliation', fixture,
  )
  assert.equal(terminal.attemptId, request.attemptId)
  const statusObservations = fs.readFileSync(observations, 'utf8').trim().split('\n')
    .filter(Boolean).map(JSON.parse)
  assert.equal(statusObservations.length > 0, true)
  assert.equal(statusObservations[0].marker, null,
    'the durable marker must not be written until Codex has reported a non-empty tool inventory')
  for (const observation of statusObservations.slice(1).filter((entry) => entry.marker != null)) {
    assert.deepEqual(JSON.parse(observation.marker), {
      schemaVersion: 1,
      revision: 'observed-credential-generation',
      servers: { [configuredMcpServerId]: 'observed-credential-generation' },
    })
  }
  assert.deepEqual(readCodexMcpCredentialMarker(fixture), {
    schemaVersion: 1,
    revision: 'observed-credential-generation',
    servers: { [configuredMcpServerId]: 'observed-credential-generation' },
  })
})

test('uncertain Codex reconciliation leaves a missing credential marker missing', async (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'mechanician-codex-reconcile-uncertain-'))
  const support = path.join(root, 'support')
  const observations = path.join(root, 'status-observations.ndjson')
  writeConfiguredMcpSidecar(support)
  t.after(() => fs.rmSync(root, { recursive: true, force: true, maxRetries: 20, retryDelay: 10 }))
  const fixture = await startAgentd(t, 'mcp-status-zero-tools', {
    MECHANICIAN_SUPPORT_DIR: support,
    MECHANICIAN_CODEX_MCP_ACTIVATION_HOLD_MS: '250',
    CODEX_FIXTURE_MCP_STATUS_OBSERVATION_FILE: observations,
  })
  fs.rmSync(observations, { force: true })

  const request = exactConfiguredMcpControl('mcp_reconcile', 'uncertain-marker-reconcile', {
    attemptId: 'unproven-credential-generation', operation: 'authorize',
  })
  send(fixture.child, request)

  const terminal = await waitFor(
    () => fixture.events.find((event) =>
      event.type === 'mcp_reconcile_error' && event.id === request.id),
    'uncertain Codex reconciliation', fixture,
  )
  assert.match(terminal.message, /could not determine|report its tools/i)
  assert.equal(fs.existsSync(codexMcpCredentialMarkerPath(fixture)), false)
  const statusObservations = fs.readFileSync(observations, 'utf8').trim().split('\n')
    .filter(Boolean).map(JSON.parse)
  assert.equal(statusObservations.length > 0, true)
  assert.equal(statusObservations.every((entry) => entry.marker === null), true)
})

test('a Codex connected row without a tool inventory cannot start the promoted thread', async (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'mechanician-codex-missing-inventory-'))
  const support = path.join(root, 'support')
  const starts = path.join(root, 'starts.ndjson')
  fs.mkdirSync(support, { recursive: true })
  fs.writeFileSync(path.join(support, 'extensions.json'), JSON.stringify({
    mcpServers: [{
      id: '7f661a72-4885-42ad-bce1-242b6741d88a',
      name: 'fixture-server', command: '/bin/echo',
    }],
  }))
  t.after(() => fs.rmSync(root, { recursive: true, force: true, maxRetries: 20, retryDelay: 10 }))
  const fixture = await startAgentd(t, 'mcp-status-no-inventory', {
    MECHANICIAN_SUPPORT_DIR: support,
    MECHANICIAN_CODEX_MCP_ACTIVATION_HOLD_MS: '250',
    CODEX_FIXTURE_THREAD_START_LOG_FILE: starts,
  })
  writeCodexMcpCredentialMarker(fixture, 'credential-change-3')
  writeConfiguredCodexReadiness(support, 'credential-change-3')

  const terminal = await runTurn(fixture, 'inventory-mcp-proof', {
    sessionId: 'codex-tools:pre-auth-thread',
    mcpReadinessClaims: [{
      name: 'fixture-server', changeId: 'credential-change-3', source: 'configured',
      serverId: '7f661a72-4885-42ad-bce1-242b6741d88a',
      accountInstanceId: 'a1faed81-8eba-4242-97fa-b3a5d9212585',
      routeIdentity: 'codex:subscription:builtin',
    }],
  })

  assert.equal(terminal.type, 'error')
  assert.match(terminal.message, /timed out waiting.*report its tools/i)
  assert.equal(fs.existsSync(starts), false)
  assert.equal(fixture.events.some((event) =>
    event.type === 'mcp_readiness_proof' && event.id === 'inventory-mcp-proof'), false)
})

test('a Codex zero-tool row cannot consume the post-auth claim or start a thread', async (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'mechanician-codex-zero-tools-'))
  const support = path.join(root, 'support')
  const starts = path.join(root, 'starts.ndjson')
  fs.mkdirSync(support, { recursive: true })
  fs.writeFileSync(path.join(support, 'extensions.json'), JSON.stringify({
    mcpServers: [{
      id: '7f661a72-4885-42ad-bce1-242b6741d88a',
      name: 'fixture-server', command: '/bin/echo',
    }],
  }))
  t.after(() => fs.rmSync(root, { recursive: true, force: true, maxRetries: 20, retryDelay: 10 }))
  const fixture = await startAgentd(t, 'mcp-status-zero-tools', {
    MECHANICIAN_SUPPORT_DIR: support,
    MECHANICIAN_CODEX_MCP_ACTIVATION_HOLD_MS: '250',
    CODEX_FIXTURE_THREAD_START_LOG_FILE: starts,
  })
  writeCodexMcpCredentialMarker(fixture, 'credential-change-4')
  writeConfiguredCodexReadiness(support, 'credential-change-4')

  const terminal = await runTurn(fixture, 'zero-tool-mcp-proof', {
    sessionId: 'codex-tools:pre-auth-thread',
    mcpReadinessClaims: [{
      name: 'fixture-server', changeId: 'credential-change-4', source: 'configured',
      serverId: '7f661a72-4885-42ad-bce1-242b6741d88a',
      accountInstanceId: 'a1faed81-8eba-4242-97fa-b3a5d9212585',
      routeIdentity: 'codex:subscription:builtin',
    }],
  })

  assert.equal(terminal.type, 'error')
  assert.match(terminal.message, /timed out waiting.*report its tools/i)
  assert.equal(fs.existsSync(starts), false)
  assert.equal(fixture.events.some((event) =>
    event.type === 'mcp_readiness_proof' && event.id === 'zero-tool-mcp-proof'), false)
})

test('configured Codex readiness survives zero tools and proves the same generation on retry', async (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'mechanician-codex-mcp-proof-retry-'))
  const support = path.join(root, 'support')
  const statusToolsFile = path.join(root, 'status-tools.txt')
  const starts = path.join(root, 'starts.ndjson')
  writeConfiguredMcpSidecar(support)
  fs.writeFileSync(statusToolsFile, 'not-ready')
  t.after(() => fs.rmSync(root, { recursive: true, force: true, maxRetries: 20, retryDelay: 10 }))
  const fixture = await startAgentd(t, 'mcp-status-file', {
    MECHANICIAN_SUPPORT_DIR: support,
    MECHANICIAN_CODEX_MCP_ACTIVATION_HOLD_MS: '250',
    CODEX_FIXTURE_MCP_STATUS_TOOLS_FILE: statusToolsFile,
    CODEX_FIXTURE_THREAD_START_LOG_FILE: starts,
  })
  const changeId = 'configured-codex-zero-tools-retry-generation'
  writeConfiguredCodexReadiness(support, changeId)
  writeCodexMcpCredentialMarker(fixture, changeId)
  const claim = {
    name: 'fixture-server', changeId, source: 'configured',
    serverId: configuredMcpServerId, accountInstanceId: mcpAccountInstanceId,
    routeIdentity: codexMcpRouteIdentity,
  }

  const first = await runTurn(fixture, 'codex-zero-tools-first-gate', {
    sessionId: 'codex-tools:pre-auth-thread', mcpReadinessClaims: [claim],
  })
  assert.equal(first.type, 'error')
  assert.match(first.message, /report its tools/i)
  assert.equal(fs.existsSync(starts), false)
  assert.equal(fixture.events.some((event) => event.type === 'mcp_readiness_proof'
    && event.id === 'codex-zero-tools-first-gate'), false)

  fs.writeFileSync(statusToolsFile, 'ready')
  const retry = await runTurn(fixture, 'codex-tools-ready-retry', {
    sessionId: 'codex-tools:pre-auth-thread', mcpReadinessClaims: [claim],
  })
  assert.deepEqual(retry, { type: 'done', id: 'codex-tools-ready-retry' })
  assert.deepEqual(fixture.events.find((event) => event.type === 'mcp_readiness_proof'
    && event.id === 'codex-tools-ready-retry'), {
    type: 'mcp_readiness_proof', id: 'codex-tools-ready-retry',
    name: 'fixture-server', changeId, source: 'configured',
    serverId: configuredMcpServerId, accountInstanceId: mcpAccountInstanceId,
    routeIdentity: codexMcpRouteIdentity, status: 'connected', tools: 1,
  })
  assert.equal(fs.readFileSync(starts, 'utf8').trim().split('\n').filter(Boolean).length, 1)
})

test('Codex prunes stale local A after sibling B was durably consumed before an ordinary turn', async (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'mechanician-codex-prune-consumed-a-'))
  const support = path.join(root, 'support')
  const starts = path.join(root, 'starts.ndjson')
  writeConfiguredMcpSidecar(support)
  t.after(() => fs.rmSync(root, { recursive: true, force: true, maxRetries: 20, retryDelay: 10 }))
  const fixture = await startAgentd(t, 'mcp-status-zero-tools', {
    MECHANICIAN_SUPPORT_DIR: support,
    MECHANICIAN_CODEX_MCP_ACTIVATION_HOLD_MS: '250',
    CODEX_FIXTURE_THREAD_START_LOG_FILE: starts,
  })
  writeConfiguredCodexReadiness(support, 'consumed-sibling-generation-a')
  writeCodexMcpCredentialMarker(fixture, 'consumed-sibling-generation-a')
  const failedA = await runTurn(fixture, 'establish-codex-local-a', {
    sessionId: 'codex-tools:pre-auth-a',
    mcpReadinessClaims: [{
      name: 'fixture-server', changeId: 'consumed-sibling-generation-a',
      source: 'configured', serverId: configuredMcpServerId,
      accountInstanceId: mcpAccountInstanceId, routeIdentity: codexMcpRouteIdentity,
    }],
  })
  assert.equal(failedA.type, 'error')
  assert.match(failedA.message, /report its tools/i)
  assert.equal(fs.existsSync(starts), false)

  writeConfiguredMcpSidecar(support)
  writeCodexMcpCredentialMarker(fixture, 'consumed-sibling-generation-b')
  const ordinary = await runTurn(fixture, 'ordinary-after-codex-sibling-b-consumed', {
    sessionId: 'codex-tools:session-after-b',
  })

  assert.deepEqual(ordinary, { type: 'done', id: 'ordinary-after-codex-sibling-b-consumed' })
  assert.equal(fixture.events.some((event) => event.type === 'mcp_readiness_proof'
    && event.id === 'ordinary-after-codex-sibling-b-consumed'), false)
  assert.equal(fs.readFileSync(starts, 'utf8').trim().split('\n').filter(Boolean).length, 1,
    'cross-daemon marker B may refresh the process, but stale local A must not readiness-gate it')
})

test('a fresh Codex daemon rejects request A when the durable ledger and marker say B', async (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'mechanician-codex-fresh-stale-a-'))
  const support = path.join(root, 'support')
  const starts = path.join(root, 'starts.ndjson')
  writeConfiguredCodexReadiness(support, 'fresh-durable-generation-b')
  t.after(() => fs.rmSync(root, {
    recursive: true, force: true, maxRetries: 20, retryDelay: 10,
  }))
  const fixture = await startAgentd(t, 'retry-success', {
    MECHANICIAN_SUPPORT_DIR: support,
    CODEX_FIXTURE_THREAD_START_LOG_FILE: starts,
  })
  writeCodexMcpCredentialMarker(fixture, 'fresh-durable-generation-b')

  const stale = await runTurn(fixture, 'fresh-codex-request-a', {
    sessionId: 'codex-tools:pre-auth-a',
    mcpReadinessClaims: [{
      name: 'fixture-server', changeId: 'fresh-stale-generation-a',
      source: 'configured', serverId: configuredMcpServerId,
      accountInstanceId: mcpAccountInstanceId, routeIdentity: codexMcpRouteIdentity,
    }],
  })
  assert.equal(stale.type, 'error')
  assert.match(stale.message, /generation changed/i)
  assert.equal(fs.existsSync(starts), false)
  assert.equal(fixture.events.some((event) => event.type === 'session'
    && event.id === 'fresh-codex-request-a'), false)
  assert.equal(fixture.events.some((event) => event.type === 'mcp_readiness_proof'
    && event.id === 'fresh-codex-request-a'), false)
})

test('a fresh Codex daemon rejects request A after a sibling consumed its ledger row', async (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'mechanician-codex-fresh-consumed-a-'))
  const support = path.join(root, 'support')
  const starts = path.join(root, 'starts.ndjson')
  writeCodexReadiness(support, [])
  t.after(() => fs.rmSync(root, {
    recursive: true, force: true, maxRetries: 20, retryDelay: 10,
  }))
  const fixture = await startAgentd(t, 'retry-success', {
    MECHANICIAN_SUPPORT_DIR: support,
    CODEX_FIXTURE_THREAD_START_LOG_FILE: starts,
  })
  writeCodexMcpCredentialMarker(fixture, 'fresh-consumed-generation-a')

  const stale = await runTurn(fixture, 'fresh-codex-consumed-a', {
    sessionId: 'codex-tools:pre-auth-a',
    mcpReadinessClaims: [{
      name: 'fixture-server', changeId: 'fresh-consumed-generation-a',
      source: 'configured', serverId: configuredMcpServerId,
      accountInstanceId: mcpAccountInstanceId, routeIdentity: codexMcpRouteIdentity,
    }],
  })
  assert.equal(stale.type, 'error')
  assert.match(stale.message, /generation changed/i)
  assert.equal(fs.existsSync(starts), false)
  assert.equal(fixture.events.some((event) => event.type === 'mcp_readiness_proof'
    && event.id === 'fresh-codex-consumed-a'), false)
})

test('Codex revalidates the durable claim after async tool polling before thread start', async (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'mechanician-codex-consume-poll-'))
  const support = path.join(root, 'support')
  const statusTools = path.join(root, 'status-tools.txt')
  const starts = path.join(root, 'starts.ndjson')
  const changeId = 'codex-consumed-during-tool-poll'
  writeConfiguredCodexReadiness(support, changeId)
  fs.writeFileSync(statusTools, 'not-ready')
  t.after(() => fs.rmSync(root, {
    recursive: true, force: true, maxRetries: 20, retryDelay: 10,
  }))
  const fixture = await startAgentd(t, 'mcp-status-file', {
    MECHANICIAN_SUPPORT_DIR: support,
    MECHANICIAN_CODEX_MCP_ACTIVATION_HOLD_MS: '30000',
    CODEX_FIXTURE_MCP_STATUS_TOOLS_FILE: statusTools,
    CODEX_FIXTURE_THREAD_START_LOG_FILE: starts,
  })
  writeCodexMcpCredentialMarker(fixture, changeId)
  send(fixture.child, {
    type: 'send', id: 'codex-consumed-during-poll',
    convId: 'conv-codex-consumed-during-poll', prompt: 'Use the authenticated tool.',
    model: 'gpt-fixture', sessionId: 'codex-tools:pre-auth-thread',
    mcpReadinessClaims: [{
      name: 'fixture-server', changeId, source: 'configured',
      serverId: configuredMcpServerId, accountInstanceId: mcpAccountInstanceId,
      routeIdentity: codexMcpRouteIdentity,
    }],
  })
  await waitFor(
    () => fixture.events.find((event) => event.id === 'codex-consumed-during-poll'
      && event.type === 'status' && event.status === 'connecting_extensions'),
    'Codex readiness polling before sibling consumption', fixture,
  )

  writeCodexReadiness(support, [])
  fs.writeFileSync(statusTools, 'ready')
  const terminal = await waitFor(
    () => fixture.events.find((event) => event.id === 'codex-consumed-during-poll'
      && ['done', 'error'].includes(event.type)),
    'Codex async-consumption rejection', fixture,
  )
  assert.equal(terminal.type, 'error')
  assert.match(terminal.message, /generation changed/i)
  assert.equal(fs.existsSync(starts), false)
  assert.equal(fixture.events.some((event) => event.type === 'mcp_readiness_proof'
    && event.id === 'codex-consumed-during-poll'), false)
  assert.equal(fixture.events.some((event) => event.type === 'session'
    && event.id === 'codex-consumed-during-poll'), false)
})

test('same-generation sibling consumption unblocks Codex Review and prewarm', async (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'mechanician-codex-advisory-consumed-'))
  const support = path.join(root, 'support')
  const resumes = path.join(root, 'resumes.ndjson')
  const reviews = path.join(root, 'reviews.ndjson')
  const changeId = 'same-generation-consumed-before-codex-advisories'
  writeConfiguredCodexReadiness(support, changeId)
  t.after(() => fs.rmSync(root, {
    recursive: true, force: true, maxRetries: 20, retryDelay: 10,
  }))
  const fixture = await startAgentd(t, 'mcp-status-zero-tools', {
    MECHANICIAN_SUPPORT_DIR: support,
    MECHANICIAN_CODEX_MCP_ACTIVATION_HOLD_MS: '250',
    CODEX_FIXTURE_RESUME_LOG_FILE: resumes,
    CODEX_FIXTURE_REVIEW_FILE: reviews,
  })
  writeCodexMcpCredentialMarker(fixture, changeId)
  const failed = await runTurn(fixture, 'establish-codex-local-before-advisories', {
    mcpReadinessClaims: [{
      name: 'fixture-server', changeId, source: 'configured',
      serverId: configuredMcpServerId, accountInstanceId: mcpAccountInstanceId,
      routeIdentity: codexMcpRouteIdentity,
    }],
  })
  assert.equal(failed.type, 'error')

  writeCodexReadiness(support, [])
  const seeded = await runTurn(fixture, 'seed-session-after-same-a-consumed')
  assert.equal(seeded.type, 'done')
  const currentSession = await waitFor(
    () => fixture.events.find((event) =>
      event.type === 'session' && event.id === 'seed-session-after-same-a-consumed')?.sessionId,
    'current Codex session after same-generation consumption', fixture,
  )
  send(fixture.child, {
    type: 'prewarm', id: 'prewarm-after-same-a-consumed',
    sessionId: currentSession, model: 'gpt-fixture',
    cwd: root, permissionMode: 'default', projectInstructions: '',
  })
  await waitFor(
    () => fs.existsSync(resumes),
    'Codex prewarm after same-generation consumption', fixture,
  )

  send(fixture.child, {
    type: 'review_start', id: 'review-after-same-a-consumed',
    convId: 'conv-review-after-consumption', cwd: root, model: 'gpt-fixture',
    target: { type: 'uncommittedChanges' },
  })
  const review = await waitFor(
    () => fixture.events.find((event) => event.id === 'review-after-same-a-consumed'
      && ['review_result', 'error', 'control_error'].includes(event.type)),
    'Codex Review after same-generation consumption', fixture,
  )
  assert.equal(review.type, 'review_result')
  assert.equal(fs.existsSync(reviews), true)
  assert.equal(fixture.child.exitCode, null)
})

for (const ledgerCase of [
  {
    label: 'missing-sidecar',
    install(support) { fs.rmSync(path.join(support, 'extensions.json'), { force: true }) },
    succeeds: true,
  },
  {
    label: 'legacy-sidecar',
    install(support) { writeConfiguredMcpSidecar(support, []) },
    succeeds: true,
  },
  {
    label: 'valid-empty-lane',
    install(support) { writeCodexReadiness(support, [], []) },
    succeeds: true,
  },
  {
    label: 'malformed-ledger',
    install(support) {
      fs.writeFileSync(path.join(support, 'extensions.json'), JSON.stringify({
        mcpServers: [], pendingMCPReadiness: [],
      }))
    },
    succeeds: false,
  },
  {
    label: 'malformed-row',
    install(support) {
      fs.writeFileSync(path.join(support, 'extensions.json'), JSON.stringify({
        mcpServers: [],
        pendingMCPReadiness: { byAccess: { codex_subscription: [{ changeId: 'partial' }] } },
      }))
    },
    succeeds: false,
  },
]) {
  test(`Codex ordinary turn treats ${ledgerCase.label} as ${ledgerCase.succeeds ? 'empty' : 'uncertain'}`, async (t) => {
    const root = fs.mkdtempSync(path.join(os.tmpdir(), 'mechanician-codex-ledger-matrix-'))
    const support = path.join(root, 'support')
    const starts = path.join(root, 'starts.ndjson')
    fs.mkdirSync(support, { recursive: true })
    ledgerCase.install(support)
    t.after(() => fs.rmSync(root, {
      recursive: true, force: true, maxRetries: 20, retryDelay: 10,
    }))
    const fixture = await startAgentd(t, 'retry-success', {
      MECHANICIAN_SUPPORT_DIR: support,
      CODEX_FIXTURE_THREAD_START_LOG_FILE: starts,
    })
    const terminal = await runTurn(fixture, `ordinary-${ledgerCase.label}`)
    if (ledgerCase.succeeds) {
      assert.equal(terminal.type, 'done')
      assert.equal(fs.existsSync(starts), true)
    } else {
      assert.equal(terminal.type, 'error')
      assert.match(terminal.message, /could not verify.*credential generation/i)
      assert.equal(fs.existsSync(starts), false)
    }
    assert.equal(fixture.child.exitCode, null)
  })
}

test('malformed present MCP ledger blocks Codex Review and prewarm without exiting', async (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'mechanician-codex-malformed-advisory-'))
  const support = path.join(root, 'support')
  const resumes = path.join(root, 'resumes.ndjson')
  fs.mkdirSync(support, { recursive: true })
  fs.writeFileSync(path.join(support, 'extensions.json'), JSON.stringify({
    mcpServers: [], pendingMCPReadiness: { byAccess: { codex_subscription: 'invalid' } },
  }))
  t.after(() => fs.rmSync(root, {
    recursive: true, force: true, maxRetries: 20, retryDelay: 10,
  }))
  const fixture = await startAgentd(t, 'retry-success', {
    MECHANICIAN_SUPPORT_DIR: support,
    CODEX_FIXTURE_RESUME_LOG_FILE: resumes,
  })
  send(fixture.child, {
    type: 'prewarm', id: 'malformed-ledger-prewarm',
    sessionId: 'codex-tools:must-not-resume', model: 'gpt-fixture', cwd: root,
    permissionMode: 'default', projectInstructions: '',
  })
  await delay(150)
  assert.equal(fs.existsSync(resumes), false)
  assert.match(fixture.stderr, /prewarm skipped reason=mcp_credential_boundary/)

  send(fixture.child, {
    type: 'review_start', id: 'malformed-ledger-review',
    convId: 'conv-malformed-ledger-review', cwd: root, model: 'gpt-fixture',
    target: { type: 'uncommittedChanges' },
  })
  const rejected = await waitFor(
    () => fixture.events.find((event) => event.type === 'control_error'
      && event.id === 'malformed-ledger-review'),
    'malformed-ledger Review rejection', fixture,
  )
  assert.match(rejected.message, /finish activating.*MCP connection/i)
  assert.equal(fixture.child.exitCode, null)
})

test('stopping during Codex MCP readiness cannot create a thread or session afterward', async (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'mechanician-codex-stop-readiness-'))
  const support = path.join(root, 'support')
  const starts = path.join(root, 'starts.ndjson')
  writeConfiguredMcpSidecar(support)
  t.after(() => fs.rmSync(root, { recursive: true, force: true, maxRetries: 20, retryDelay: 10 }))
  const fixture = await startAgentd(t, 'mcp-status-zero-tools', {
    MECHANICIAN_SUPPORT_DIR: support,
    MECHANICIAN_CODEX_MCP_ACTIVATION_HOLD_MS: '30000',
    CODEX_FIXTURE_THREAD_START_LOG_FILE: starts,
  })
  writeCodexMcpCredentialMarker(fixture, 'stop-readiness-generation')
  writeConfiguredCodexReadiness(support, 'stop-readiness-generation')

  send(fixture.child, {
    type: 'send', id: 'stop-mcp-readiness', convId: 'conv-stop-mcp-readiness',
    sessionId: 'codex-tools:pre-auth-thread', prompt: 'Use the new MCP tools.',
    model: 'gpt-fixture',
    mcpReadinessClaims: [{
      name: 'fixture-server', changeId: 'stop-readiness-generation',
      source: 'configured', serverId: configuredMcpServerId,
      accountInstanceId: mcpAccountInstanceId, routeIdentity: codexMcpRouteIdentity,
    }],
  })
  await waitFor(
    () => fixture.events.find((event) => event.id === 'stop-mcp-readiness'
      && event.type === 'status' && event.status === 'connecting_extensions'),
    'Codex MCP readiness wait', fixture,
  )
  send(fixture.child, {
    type: 'interrupt', id: 'interrupt-mcp-readiness', turnId: 'stop-mcp-readiness',
  })

  const terminal = await waitFor(
    () => fixture.events.find((event) => event.id === 'stop-mcp-readiness'
      && (event.type === 'done' || event.type === 'error')),
    'interrupted MCP readiness terminal', fixture,
  )
  assert.deepEqual(terminal, {
    type: 'done', id: 'stop-mcp-readiness', interrupted: true,
  })
  await delay(300)
  assert.equal(fs.existsSync(starts), false)
  assert.equal(fixture.events.some((event) =>
    event.type === 'mcp_readiness_proof' && event.id === 'stop-mcp-readiness'), false)
  assert.equal(fixture.events.some((event) =>
    event.type === 'session' && event.id === 'stop-mcp-readiness'), false)
})

test('Codex OAuth reload failure never claims the server is ready', async (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'mechanician-codex-oauth-reload-fail-'))
  const reload = path.join(root, 'reload.txt')
  const support = path.join(root, 'support')
  writeConfiguredMcpSidecar(support)
  t.after(() => fs.rmSync(root, { recursive: true, force: true }))
  const fixture = await startAgentd(t, 'oauth-complete-reload-fails', {
    MECHANICIAN_SUPPORT_DIR: support,
    CODEX_FIXTURE_MCP_RELOAD_FILE: reload,
  })

  send(fixture.child, exactConfiguredMcpControl(
    'mcp_authorize', 'oauth-reload-failure'))
  const terminal = await waitFor(
    () => fixture.events.find((event) => event.id === 'oauth-reload-failure'
      && ['mcp_authorize_ok', 'mcp_authorize_error'].includes(event.type)),
    'failed Codex MCP reload terminal', fixture,
  )

  assert.equal(fs.existsSync(reload), true)
  assert.equal(terminal.type, 'mcp_authorize_error')
  assert.match(terminal.message, /could not activate/i)
  assert.equal(typeof terminal.changeId, 'string')
  assert.ok(fixture.events.some((event) => event.type === 'mcp_credentials_changed'
    && event.changeId === terminal.changeId && event.activation === 'failed'))
  assert.equal(
    fixture.events.some((event) => event.type === 'mcp_authorize_ok'
      && event.id === 'oauth-reload-failure'),
    false)
})

test('Codex clear-auth success stays behind the live MCP reload boundary', async (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'mechanician-codex-clear-reload-'))
  const logout = path.join(root, 'logout.txt')
  const reload = path.join(root, 'reload.txt')
  const support = path.join(root, 'support')
  writeConfiguredMcpSidecar(support)
  t.after(() => fs.rmSync(root, { recursive: true, force: true }))
  const fixture = await startAgentd(t, 'clear-auth-reload', {
    MECHANICIAN_SUPPORT_DIR: support,
    CODEX_FIXTURE_MCP_LOGOUT_FILE: logout,
    CODEX_FIXTURE_MCP_RELOAD_FILE: reload,
  })

  send(fixture.child, exactConfiguredMcpControl(
    'mcp_clear_auth', 'clear-reload-boundary'))
  await waitFor(
    () => fs.existsSync(logout) && fs.existsSync(reload),
    'Codex MCP logout and reload start', fixture,
  )
  assert.match(fs.readFileSync(logout, 'utf8'), /mcp\nlogout\nfixture-server/)
  assert.equal(
    fixture.events.some((event) => event.type === 'mcp_clear_auth_ok'
      && event.id === 'clear-reload-boundary'),
    false,
    'removing the credential is not converged until the live provider reload completes')

  const terminal = await waitFor(
    () => fixture.events.find((event) => event.type === 'mcp_clear_auth_ok'
      && event.id === 'clear-reload-boundary'),
    'post-reload Codex MCP clear-auth terminal', fixture,
  )
  assert.equal(terminal.changeId, 'clear-reload-boundary-attempt')
  assert.equal(terminal.source, 'configured')
  assert.equal(terminal.serverId, configuredMcpServerId)
  assert.equal(terminal.accountInstanceId, mcpAccountInstanceId)
  assert.equal(terminal.routeIdentity, codexMcpRouteIdentity)
  await waitFor(
    () => fixture.events.find((event) =>
      event.type === 'mcp_credentials_changed'
        && event.changeId === terminal.changeId
        && event.accountInstanceId === mcpAccountInstanceId
        && event.routeIdentity === codexMcpRouteIdentity
        && event.activation === 'cleared'),
    'post-reload Codex MCP cleared publication', fixture,
  )
})

test('Codex provider exit during OAuth start emits exactly one id-bound terminal', async (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'mechanician-codex-oauth-exit-'))
  const starts = path.join(root, 'starts.txt')
  const support = path.join(root, 'support')
  writeConfiguredMcpSidecar(support)
  t.after(() => fs.rmSync(root, { recursive: true, force: true }))
  const fixture = await startAgentd(t, 'oauth-start-exit', {
    MECHANICIAN_SUPPORT_DIR: support,
    CODEX_FIXTURE_START_FILE: starts,
    MECHANICIAN_CODEX_RESTART_BASE_MS: '20',
    MECHANICIAN_CODEX_RESTART_MAX_MS: '20',
  })

  send(fixture.child, exactConfiguredMcpControl(
    'mcp_authorize', 'oauth-provider-exit'))
  const terminal = await waitFor(
    () => fixture.events.find((event) => event.type === 'mcp_authorize_error'
      && event.id === 'oauth-provider-exit'),
    'provider-exit OAuth terminal', fixture,
  )
  assert.match(terminal.message, /stopped during authorization/)
  await delay(150)
  assert.equal(
    fixture.events.filter((event) => event.type === 'mcp_authorize_error'
      && event.id === 'oauth-provider-exit').length,
    1,
    'transport rejection cannot publish a second terminal after provider-exit cleanup',
  )
  await waitFor(
    () => fs.readFileSync(starts, 'utf8').trim().split('\n').filter(Boolean).length >= 2,
    'replacement after OAuth provider exit', fixture, 2_000,
  )
})

test('automatic ready refreshes cannot reopen an exhausted Codex restart circuit', async (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'mechanician-codex-residency-circuit-'))
  const starts = path.join(root, 'starts.txt')
  t.after(() => fs.rmSync(root, { recursive: true, force: true }))
  const fixture = await startAgentd(t, 'ready-exit-loop', {
    CODEX_FIXTURE_START_FILE: starts,
    MECHANICIAN_CODEX_RESTART_BASE_MS: '20',
    MECHANICIAN_CODEX_RESTART_MAX_MS: '20',
    MECHANICIAN_CODEX_RESTART_LIMIT: '1',
    MECHANICIAN_CODEX_RESTART_STABLE_MS: '2000',
  })
  await waitFor(
    () => fixture.events.find((event) => event.type === 'info'
      && /automatic restart paused/.test(event.message)),
    'exhausted Codex restart circuit', fixture, 30_000,
  )
  assert.equal(
    fs.readFileSync(starts, 'utf8').trim().split('\n').filter(Boolean).length,
    2,
  )

  // These are all automatic consequences of projecting/readying a selected lane. None is an
  // explicit turn, account recovery, or authorization command.
  send(fixture.child, { type: 'provider_residency', active: true })
  send(fixture.child, { type: 'model_catalog', id: 'circuit-catalog' })
  send(fixture.child, {
    type: 'prewarm', id: 'circuit-prewarm',
    sessionId: 'codex-tools:circuit-thread', model: 'gpt-fixture', cwd: root,
  })
  await waitFor(
    () => fixture.events.find((event) => event.type === 'model_catalog_error'
      && event.id === 'circuit-catalog'),
    'catalog failure from open circuit', fixture,
  )
  await delay(150)
  assert.equal(
    fs.readFileSync(starts, 'utf8').trim().split('\n').filter(Boolean).length,
    2,
    'ready-time catalog, prewarm, and residency advisories cannot reopen the circuit',
  )
  assert.equal(
    fixture.events.filter((event) => event.type === 'info'
      && /automatic restart paused/.test(event.message)).length,
    1,
  )
})

test('automatic ready refreshes cannot shorten Codex restart backoff', async (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'mechanician-codex-residency-backoff-'))
  const starts = path.join(root, 'starts.txt')
  t.after(() => fs.rmSync(root, { recursive: true, force: true }))
  const fixture = await startAgentd(t, 'ready-exit-loop', {
    CODEX_FIXTURE_START_FILE: starts,
    MECHANICIAN_CODEX_RESTART_BASE_MS: '400',
    MECHANICIAN_CODEX_RESTART_MAX_MS: '400',
    MECHANICIAN_CODEX_RESTART_LIMIT: '2',
    MECHANICIAN_CODEX_RESTART_STABLE_MS: '2000',
  })
  await waitFor(
    () => fixture.events.find((event) => event.type === 'info'
      && /restarting after its App Server stopped/.test(event.message)),
    'scheduled Codex restart', fixture,
  )
  assert.equal(
    fs.readFileSync(starts, 'utf8').trim().split('\n').filter(Boolean).length,
    1,
  )

  send(fixture.child, { type: 'provider_residency', active: true })
  send(fixture.child, { type: 'model_catalog', id: 'backoff-catalog' })
  send(fixture.child, {
    type: 'prewarm', id: 'backoff-prewarm',
    sessionId: 'codex-tools:backoff-thread', model: 'gpt-fixture', cwd: root,
  })
  await delay(150)
  assert.equal(
    fs.readFileSync(starts, 'utf8').trim().split('\n').filter(Boolean).length,
    1,
    'automatic refreshes leave the scheduled backoff delay intact',
  )
  await waitFor(
    () => fs.readFileSync(starts, 'utf8').trim().split('\n').filter(Boolean).length >= 2,
    'replacement after the original backoff', fixture, 2_000,
  )
})

test('Codex Connect gets one explicit retry after a signed-out restart circuit opens', async (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'mechanician-codex-connect-retry-'))
  const starts = path.join(root, 'starts.txt')
  t.after(() => fs.rmSync(root, { recursive: true, force: true }))
  const fixture = await startAgentd(t, 'ready-exit-loop-signed-out', {
    CODEX_FIXTURE_START_FILE: starts,
    MECHANICIAN_CODEX_RESTART_BASE_MS: '10',
    MECHANICIAN_CODEX_RESTART_MAX_MS: '10',
    MECHANICIAN_CODEX_RESTART_LIMIT: '2',
    MECHANICIAN_CODEX_RESTART_STABLE_MS: '2000',
  })

  await waitFor(
    () => fixture.events.find((event) => event.type === 'info'
      && /automatic restart paused/.test(event.message)),
    'signed-out Codex restart pause', fixture, 30000,
  )
  assert.equal(fixture.events.filter((event) => event.type === 'ready').at(-1).mode, 'unavailable')
  assert.equal(fixture.events.filter((event) => event.type === 'ready').at(-1).loggedIn, false)
  assert.equal(
    fs.readFileSync(starts, 'utf8').trim().split('\n').filter(Boolean).length,
    3,
  )

  send(fixture.child, { type: 'login_start', id: 'connect-after-pause' })
  const started = await waitFor(
    () => fixture.events.find((event) => event.type === 'login_started'
      && event.id === 'connect-after-pause'),
    'explicit Connect retry', fixture,
  )
  assert.equal(started.url, 'https://example.test/codex-login')
  const terminal = await waitFor(
    () => fixture.events.find((event) => event.type === 'login_error'
      && event.id === 'connect-after-pause'),
    'failed Connect terminal', fixture,
  )
  assert.match(terminal.message, /stopped during sign-in/)
  await waitFor(
    () => fixture.events.filter((event) => event.type === 'info'
      && /automatic restart paused/.test(event.message)).length === 2,
    'post-Connect restart pause', fixture,
  )
  await delay(100)
  assert.equal(
    fs.readFileSync(starts, 'utf8').trim().split('\n').filter(Boolean).length,
    4,
    'Connect starts exactly one replacement and does not reopen automatic retries',
  )
})

test('Codex reconnect still starts OAuth on an already-healthy signed-in App Server', async (t) => {
  const fixture = await startAgentd(t, 'retry-success')

  send(fixture.child, { type: 'login_start', id: 'healthy-reconnect' })
  const started = await waitFor(
    () => fixture.events.find((event) => event.type === 'login_started'
      && event.id === 'healthy-reconnect'),
    'healthy reconnect OAuth start', fixture,
  )
  assert.equal(started.url, 'https://example.test/codex-login')
  assert.match(fixture.stderr, /ACCOUNT_LOGIN_START/)
})

test('Codex Connect accepts a recovered App Server account without redundant OAuth', async (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'mechanician-codex-account-recovered-'))
  const starts = path.join(root, 'starts.txt')
  t.after(() => fs.rmSync(root, { recursive: true, force: true }))
  const fixture = await startAgentd(t, 'ready-exit-loop-account-recovers', {
    CODEX_FIXTURE_START_FILE: starts,
    MECHANICIAN_CODEX_RESTART_BASE_MS: '10',
    MECHANICIAN_CODEX_RESTART_MAX_MS: '10',
    MECHANICIAN_CODEX_RESTART_LIMIT: '2',
    MECHANICIAN_CODEX_RESTART_STABLE_MS: '2000',
  })

  await waitFor(
    () => fixture.events.find((event) => event.type === 'info'
      && /automatic restart paused/.test(event.message)),
    'signed-out circuit before account recovery', fixture, 30000,
  )
  send(fixture.child, { type: 'login_start', id: 'connect-account-recovered' })
  const completed = await waitFor(
    () => fixture.events.find((event) => event.type === 'login_ok'
      && event.id === 'connect-account-recovered'),
    'recovered account completion', fixture,
  )
  assert.equal(completed.loggedIn, true)
  await delay(100)
  assert.equal(
    fs.readFileSync(starts, 'utf8').trim().split('\n').filter(Boolean).length,
    4,
  )
  assert.equal(fixture.events.some((event) => event.type === 'login_started'
    && event.id === 'connect-account-recovered'), false)
  assert.doesNotMatch(fixture.stderr, /ACCOUNT_LOGIN_START/)
  assert.equal(fixture.events.filter((event) => event.type === 'ready').at(-1).mode, 'sdk')
  assert.equal(fixture.events.filter((event) => event.type === 'ready').at(-1).loggedIn, true)
})

test('Codex replenishes the automatic restart budget only after sustained health', async (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'mechanician-codex-restart-stable-'))
  const starts = path.join(root, 'starts.txt')
  t.after(() => fs.rmSync(root, { recursive: true, force: true }))
  const fixture = await startAgentd(t, 'ready-exit-stability-reset', {
    CODEX_FIXTURE_START_FILE: starts,
    MECHANICIAN_CODEX_RESTART_BASE_MS: '10',
    MECHANICIAN_CODEX_RESTART_MAX_MS: '10',
    MECHANICIAN_CODEX_RESTART_LIMIT: '1',
    MECHANICIAN_CODEX_RESTART_STABLE_MS: '50',
  })

  await waitFor(
    () => fs.readFileSync(starts, 'utf8').trim().split('\n').filter(Boolean).length === 3,
    'replacement after the stable child exits', fixture, 30000,
  )
  await waitFor(
    () => fixture.events.filter((event) => event.type === 'ready'
      && event.mode === 'sdk').length >= 3,
    'third Codex child ready', fixture,
  )
  await delay(100)
  assert.equal(
    fs.readFileSync(starts, 'utf8').trim().split('\n').filter(Boolean).length,
    3,
    'the third child remains resident',
  )
  assert.doesNotMatch(fixture.stderr, /automatic restart paused/)
  assert.match(fixture.stderr, /automatic restart budget reset/)
  assert.equal(
    fixture.events.filter((event) => event.type === 'info'
      && /automatic restart paused/.test(event.message)).length,
    0,
  )
})

test('App Server exit after turn/start response but before notifications terminalizes once', async (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'mechanician-codex-start-exit-'))
  const starts = path.join(root, 'starts.txt')
  t.after(() => fs.rmSync(root, { recursive: true, force: true }))
  const fixture = await startAgentd(t, 'exit-after-start-response', {
    CODEX_FIXTURE_START_FILE: starts,
    MECHANICIAN_CODEX_RESTART_BASE_MS: '20',
    MECHANICIAN_CODEX_RESTART_MAX_MS: '20',
  })

  const terminal = await runTurn(fixture, 'start-response-exit', { effort: 'ultra' })

  assert.equal(terminal.type, 'error')
  assert.equal(terminal.providerError.code, 'app_server_exit')
  assert.match(fixture.stderr, /"event":"provider_route_terminalized"/)
  assert.match(fixture.stderr, /"restartReason":/)
  assertOneTerminal(fixture, 'start-response-exit')
  await waitFor(
    () => fs.readFileSync(starts, 'utf8').trim().split('\n').filter(Boolean).length >= 2,
    'replacement after response-notification exit', fixture,
  )
})

test('unanswered Codex interrupt force-stops the turn and restarts the authenticated lane', async (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'mechanician-codex-interrupt-'))
  const starts = path.join(root, 'starts.txt')
  const turns = path.join(root, 'turns.jsonl')
  t.after(() => fs.rmSync(root, { recursive: true, force: true }))
  const fixture = await startAgentd(t, 'interrupt-stall', {
    CODEX_FIXTURE_START_FILE: starts,
    CODEX_FIXTURE_TURN_FILE: turns,
    MECHANICIAN_CODEX_INTERRUPT_GRACE_MS: '40',
    MECHANICIAN_CODEX_RESTART_BASE_MS: '20',
    MECHANICIAN_CODEX_RESTART_MAX_MS: '20',
    MECHANICIAN_CODEX_FORCE_KILL_GRACE_MS: '0',
  })

  send(fixture.child, { type: 'send', id: 'turn-stalled', convId: 'conv-stalled', prompt: 'hold' })
  await waitFor(() => fs.existsSync(turns) && fs.statSync(turns).size > 0,
                'stalled provider turn start', fixture)
  send(fixture.child, { type: 'interrupt', id: 'stop-stalled', turnId: 'turn-stalled' })

  const terminal = await waitFor(
    () => fixture.events.find((event) => event.id === 'turn-stalled'
      && (event.type === 'done' || event.type === 'error')),
    'forced interrupt terminal', fixture,
  )
  assert.deepEqual(terminal, { type: 'done', id: 'turn-stalled', interrupted: true })
  assertOneTerminal(fixture, 'turn-stalled')
  await waitFor(
    () => fs.readFileSync(starts, 'utf8').trim().split('\n').filter(Boolean).length >= 2,
    'post-interrupt App Server replacement', fixture,
  )
  await waitFor(
    () => fixture.events.filter((event) => event.type === 'ready' && event.mode === 'sdk').length >= 2,
    'post-interrupt authenticated ready event', fixture, 30000,
  )
  assert.ok(fixture.events.some((event) => event.type === 'ready'
    && event.mode === 'starting' && event.loggedIn === true))
  assert.equal(fixture.events.filter((event) => event.type === 'ready').at(-1).loggedIn, true)
})

test('closing the app control pipe bounds daemon drain and kills a stalled App Server', async (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'mechanician-codex-drain-'))
  const pidFile = path.join(root, 'codex.pid')
  const turns = path.join(root, 'turns.jsonl')
  t.after(() => fs.rmSync(root, { recursive: true, force: true }))
  const fixture = await startAgentd(t, 'interrupt-stall', {
    CODEX_FIXTURE_PID_FILE: pidFile,
    CODEX_FIXTURE_TURN_FILE: turns,
    MECHANICIAN_DRAIN_TIMEOUT_MS: '80',
  })
  send(fixture.child, { type: 'send', id: 'turn-drain', convId: 'conv-drain', prompt: 'hold' })
  await waitFor(() => fs.existsSync(turns) && fs.statSync(turns).size > 0,
                'provider turn before control close', fixture)
  const codexPid = Number(fs.readFileSync(pidFile, 'utf8'))
  const startedAt = Date.now()

  fixture.child.stdin.end()
  await waitFor(() => fixture.child.exitCode != null, 'bounded daemon drain exit', fixture, 2_000)
  await waitFor(() => {
    try { process.kill(codexPid, 0); return false } catch { return true }
  }, 'stalled App Server exit', fixture, 2_000)

  assert.equal(fixture.child.exitCode, 0)
  assert.ok(Date.now() - startedAt < 1_500)
})

test('a broken app event pipe bounds daemon lifetime and kills a stalled App Server', async (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'mechanician-codex-event-pipe-'))
  const pidFile = path.join(root, 'codex.pid')
  const turns = path.join(root, 'turns.jsonl')
  t.after(() => fs.rmSync(root, { recursive: true, force: true }))
  const fixture = await startAgentd(t, 'interrupt-stall', {
    CODEX_FIXTURE_PID_FILE: pidFile,
    CODEX_FIXTURE_TURN_FILE: turns,
    MECHANICIAN_DRAIN_TIMEOUT_MS: '80',
  })
  send(fixture.child, { type: 'send', id: 'turn-pipe', convId: 'conv-pipe', prompt: 'hold' })
  await waitFor(() => fs.existsSync(turns) && fs.statSync(turns).size > 0,
                'provider turn before event pipe failure', fixture)
  const codexPid = Number(fs.readFileSync(pidFile, 'utf8'))

  fixture.child.stdout.destroy()
  send(fixture.child, { type: 'ping', id: 'break-event-pipe' })
  await waitFor(() => fixture.child.exitCode != null, 'event-pipe daemon exit', fixture, 2_000)
  await waitFor(() => {
    try { process.kill(codexPid, 0); return false } catch { return true }
  }, 'event-pipe App Server exit', fixture, 2_000)

  assert.equal(fixture.child.exitCode, 0)
})

test('signed-out Codex send returns authentication failure without mock assistant output', async (t) => {
  const fixture = await startAgentd(t, 'signed-out')
  const terminal = await runTurn(fixture)

  assert.equal(terminal.type, 'error')
  assert.equal(terminal.errorKind, 'authentication')
  assert.equal(terminal.provider, 'codex')
  assert.equal(terminal.access, 'codex_subscription')
  assert.equal(fixture.events.some((event) => event.type === 'delta' && event.id === 'turn-1'), false)
  assertOneTerminal(fixture, 'turn-1')
})

test('unavailable Codex App Server returns an error without mock assistant output', async (t) => {
  const fixture = await startAgentd(t, 'startup-exit')
  const terminal = await runTurn(fixture)

  assert.equal(terminal.type, 'error')
  assert.equal(terminal.provider, 'codex')
  assert.equal(terminal.access, 'codex_subscription')
  assert.match(terminal.message, /not ready/i)
  assert.equal(fixture.events.some((event) => event.type === 'delta' && event.id === 'turn-1'), false)
  assertOneTerminal(fixture, 'turn-1')
})

/// Settings that must hold for the whole Codex process travel as `-c` overrides, because a bare
/// top-level key written into our managed config region would bind to whichever table precedes it.
/// They have to precede the subcommand, which is the placement the pinned binary accepts.
test('CodexAppServer passes config overrides ahead of the subcommand', async () => {
  let seen = null
  const app = new CodexAppServer({
    executable: '/fixture/codex',
    env: {},
    args: ['-c', 'mcp_oauth_credentials_store="keyring"'],
    spawnProcess: (file, args) => {
      seen = args
      const child = makeTransportChild((message, target) => {
        if (message.method === 'initialize') queueMicrotask(() => target.send({ id: message.id, result: {} }))
      })
      return child
    },
  })
  await app.start()

  assert.deepEqual(seen, ['-c', 'mcp_oauth_credentials_store="keyring"', 'app-server', '--stdio'])
  app.close?.()
})
