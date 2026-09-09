import assert from 'node:assert/strict'
import { EventEmitter } from 'node:events'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { test } from 'node:test'

import {
  codexMcpGenerationAction,
  codexMcpRetainedExclusions,
  codexMcpThreadSchemaState,
  codexSessionForThread,
  codexThreadSession,
  codexThreadSessionHasProfileMismatch,
  codexThreadSessionNeedsReplacement,
  createCodexMcpGenerationCoordinator,
  publishCodexMcpCredentialGeneration,
  readCodexMcpCredentialGeneration,
  waitForCodexProcessExit,
} from '../src/codex-mcp-generation.mjs'

function deferred() {
  let resolve
  let reject
  const promise = new Promise((accept, fail) => {
    resolve = accept
    reject = fail
  })
  return { promise, resolve, reject }
}

async function microtask() {
  await Promise.resolve()
  await Promise.resolve()
}

test('a generation invalidates synchronously and publishes completion only after apply', async () => {
  const applyGate = deferred()
  const observations = []
  const coordinator = createCodexMcpGenerationCoordinator({
    invalidate: (reason, generation) => observations.push({ reason, generation }),
  })

  const request = coordinator.request('OAuth completed', async ({ generation, reason }) => {
    observations.push({ applying: generation, reason })
    await applyGate.promise
  })

  assert.deepEqual(observations, [{ reason: 'OAuth completed', generation: 1 }])
  assert.equal(coordinator.pending, true)
  assert.equal(coordinator.requestedGeneration, 1)
  assert.equal(coordinator.completedGeneration, 0)

  await microtask()
  assert.deepEqual(observations, [
    { reason: 'OAuth completed', generation: 1 },
    { applying: 1, reason: 'OAuth completed' },
  ])
  assert.equal(coordinator.completedGeneration, 0)

  applyGate.resolve()
  await request
  assert.equal(coordinator.pending, false)
  assert.equal(coordinator.completedGeneration, 1)
})

test('configuration generations serialize and awaitReady follows the newest queued tail', async () => {
  const firstGate = deferred()
  const secondGate = deferred()
  const order = []
  const coordinator = createCodexMcpGenerationCoordinator()

  const first = coordinator.request('first', async ({ generation }) => {
    order.push(`start-${generation}`)
    await firstGate.promise
    order.push(`end-${generation}`)
  })
  const ready = coordinator.awaitReady().then(() => order.push('ready'))

  await microtask()
  const second = coordinator.request('second', async ({ generation }) => {
    order.push(`start-${generation}`)
    await secondGate.promise
    order.push(`end-${generation}`)
  })
  assert.equal(coordinator.requestedGeneration, 2)

  firstGate.resolve()
  await first
  await microtask()
  assert.deepEqual(order, ['start-1', 'end-1', 'start-2'])
  assert.equal(coordinator.completedGeneration, 1)

  secondGate.resolve()
  await Promise.all([second, ready])
  assert.deepEqual(order, ['start-1', 'end-1', 'start-2', 'end-2', 'ready'])
  assert.equal(coordinator.completedGeneration, 2)
  assert.equal(coordinator.pending, false)
})

test('a failed generation surfaces and does not poison a later repair', async () => {
  const coordinator = createCodexMcpGenerationCoordinator()
  const failure = new Error('reload failed')
  const failed = coordinator.request('broken', async () => { throw failure })
  const repaired = coordinator.request('retry', async ({ generation }) => generation)

  await assert.rejects(failed, failure)
  assert.equal(await repaired, 2)
  assert.equal(await coordinator.awaitReady(), 2)
  assert.equal(coordinator.completedGeneration, 2)
  assert.equal(coordinator.pending, false)
})

test('awaitReady rejects instead of claiming a failed generation is usable', async () => {
  const coordinator = createCodexMcpGenerationCoordinator()
  const failed = coordinator.request('OAuth completed', async () => {
    throw new Error('durable MCP generation save failed')
  })
  const ready = coordinator.awaitReady()

  await assert.rejects(failed, /durable MCP generation save failed/)
  await assert.rejects(
    ready,
    /durable MCP generation save failed/,
    'OAuth success and fresh thread creation must both remain behind the failed apply boundary')
  assert.equal(coordinator.completedGeneration, 0)
})

test('credential environment changes require restart while definition-only changes reload', () => {
  const changed = (left, right) => JSON.stringify(left) !== JSON.stringify(right)

  assert.equal(codexMcpGenerationAction({
    hasApp: false,
    previousEnv: { MECHANICIAN_MCP_OLD: 'old' },
    nextEnv: { MECHANICIAN_MCP_NEW: 'new' },
    envChanged: changed,
  }), 'persisted')
  assert.equal(codexMcpGenerationAction({
    hasApp: true,
    previousEnv: { MECHANICIAN_MCP_TOKEN: 'same' },
    nextEnv: { MECHANICIAN_MCP_TOKEN: 'same' },
    envChanged: changed,
  }), 'reload')
  assert.equal(codexMcpGenerationAction({
    hasApp: true,
    previousEnv: { MECHANICIAN_MCP_TOKEN: 'old' },
    nextEnv: { MECHANICIAN_MCP_TOKEN: 'rotated' },
    envChanged: changed,
  }), 'restart')
  assert.equal(codexMcpGenerationAction({
    hasApp: true,
    previousEnv: { MECHANICIAN_MCP_TOKEN: 'old' },
    nextEnv: {},
    envChanged: changed,
  }), 'restart', 'clearing a secret cannot leave the old process environment alive')
})

test('shell exclusions retain both process generations without retaining secret values', () => {
  assert.deepEqual(codexMcpRetainedExclusions(
    { MECHANICIAN_MCP_OLD: 'do-not-retain-this-value', SHARED: 'old' },
    { MECHANICIAN_MCP_NEW: 'also-secret', SHARED: 'new' },
    null,
  ), ['MECHANICIAN_MCP_NEW', 'MECHANICIAN_MCP_OLD', 'SHARED'])
})

test('Codex sessions carry the non-secret MCP schema generation', (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'codex-mcp-thread-schema-'))
  const extensionsFile = path.join(root, 'extensions.json')
  const codexHome = path.join(root, 'codex')
  fs.writeFileSync(extensionsFile, JSON.stringify({
    mcpServers: [{ name: 'fixture', command: '/bin/echo' }],
  }))
  t.after(() => fs.rmSync(root, { recursive: true, force: true }))

  const before = codexMcpThreadSchemaState({ extensionsFile, codexHome })
  const sessionId = codexSessionForThread('thread-1', before.fingerprint, 'standard')

  assert.deepEqual(codexThreadSession(sessionId), {
    threadId: 'thread-1', mcpFingerprint: before.fingerprint, toolProfile: 'standard',
  })
  assert.equal(codexThreadSessionNeedsReplacement(sessionId, before), false)
  assert.equal(
    codexThreadSessionNeedsReplacement('codex-tools:legacy-thread', before),
    true,
    'a legacy thread is replaced once when MCP is configured')

  publishCodexMcpCredentialGeneration(codexHome, 'oauth-generation-2')
  const after = codexMcpThreadSchemaState({ extensionsFile, codexHome })
  assert.notEqual(after.fingerprint, before.fingerprint)
  assert.equal(codexThreadSessionNeedsReplacement(sessionId, after), true)
})

test('Codex sessions bind threads to one immutable tool profile', () => {
  const fingerprint = 'a'.repeat(64)
  const helpSession = codexSessionForThread('help-thread', fingerprint, 'help-expert')

  assert.deepEqual(codexThreadSession(helpSession), {
    threadId: 'help-thread', mcpFingerprint: fingerprint, toolProfile: 'help-expert',
  })
  assert.equal(codexThreadSessionHasProfileMismatch(helpSession, 'help-expert'), false)
  assert.equal(codexThreadSessionHasProfileMismatch(helpSession, 'standard'), true)
  assert.equal(
    codexThreadSessionHasProfileMismatch('codex-tools:legacy-standard-thread', 'standard'),
    false,
  )
  assert.equal(
    codexThreadSessionHasProfileMismatch('codex-tools:legacy-standard-thread', 'help-expert'),
    true,
  )
})

test('credential generations remain exact per configured server', (t) => {
  const codexHome = fs.mkdtempSync(path.join(os.tmpdir(), 'codex-mcp-generations-'))
  const firstID = '7f661a72-4885-42ad-bce1-242b6741d88a'
  const secondID = 'e65b4b19-4cf3-4f45-b65d-4536bf6bf023'
  t.after(() => fs.rmSync(codexHome, { recursive: true, force: true }))

  publishCodexMcpCredentialGeneration(codexHome, 'first-generation', firstID)
  publishCodexMcpCredentialGeneration(codexHome, 'second-generation', secondID)

  assert.equal(readCodexMcpCredentialGeneration(codexHome, firstID), 'first-generation')
  assert.equal(readCodexMcpCredentialGeneration(codexHome, secondID), 'second-generation')
  assert.equal(readCodexMcpCredentialGeneration(codexHome), 'second-generation')
})

test('ledger-only extension saves do not invalidate Codex thread schema', (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'codex-mcp-semantic-schema-'))
  const extensionsFile = path.join(root, 'extensions.json')
  const codexHome = path.join(root, 'codex')
  const server = { name: 'fixture', command: '/bin/echo' }
  t.after(() => fs.rmSync(root, { recursive: true, force: true }))
  fs.writeFileSync(extensionsFile, JSON.stringify({
    providerConfigurationRevision: 'revision-a',
    mcpServers: [server],
    pendingMCPReadiness: { byAccess: { codex_subscription: ['old-ledger-shape'] } },
  }))
  const before = codexMcpThreadSchemaState({ extensionsFile, codexHome })

  fs.writeFileSync(extensionsFile, JSON.stringify({
    registrySources: [{ name: 'unrelated browser catalog' }],
    pendingMCPReadiness: { byAccess: {} },
    mcpServers: [{ command: '/bin/echo', name: 'fixture' }],
    providerConfigurationRevision: 'revision-a',
  }, null, 2))
  const ledgerOnly = codexMcpThreadSchemaState({ extensionsFile, codexHome })
  assert.deepEqual(ledgerOnly, before)

  fs.writeFileSync(extensionsFile, JSON.stringify({
    providerConfigurationRevision: 'revision-b', mcpServers: [server],
  }))
  assert.notEqual(
    codexMcpThreadSchemaState({ extensionsFile, codexHome }).fingerprint,
    before.fingerprint,
  )
})

test('legacy Codex sessions remain resumable when MCP has never been configured', (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'codex-no-mcp-thread-schema-'))
  const extensionsFile = path.join(root, 'extensions.json')
  const codexHome = path.join(root, 'codex')
  fs.writeFileSync(extensionsFile, JSON.stringify({ mcpServers: [] }))
  t.after(() => fs.rmSync(root, { recursive: true, force: true }))

  const schema = codexMcpThreadSchemaState({ extensionsFile, codexHome })

  assert.equal(schema.requiresProof, false)
  assert.equal(
    codexThreadSessionNeedsReplacement('codex-tools:legacy-thread', schema),
    false,
  )
})

test('a process replacement does not complete until the old child exits', async () => {
  const child = new EventEmitter()
  child.exitCode = null
  child.signalCode = null
  let settled = false
  const exit = waitForCodexProcessExit(child, { timeoutMs: 100 })
    .then(() => { settled = true })

  await microtask()
  assert.equal(settled, false)
  assert.equal(child.listenerCount('exit'), 1)
  assert.equal(child.listenerCount('error'), 1)

  child.exitCode = 0
  child.emit('exit', 0, null)
  await exit
  assert.equal(settled, true)
  assert.equal(child.listenerCount('exit'), 0)
  assert.equal(child.listenerCount('error'), 0)
})

test('an already-exited process generation is an immediate boundary', async () => {
  const child = new EventEmitter()
  child.exitCode = 0
  child.signalCode = null

  await waitForCodexProcessExit(child, { timeoutMs: 1 })

  assert.equal(child.listenerCount('exit'), 0)
  assert.equal(child.listenerCount('error'), 0)
})

test('a child error is not mistaken for process exit', async () => {
  const child = new EventEmitter()
  child.exitCode = null
  child.signalCode = null
  const failure = new Error('child process failure')
  const exit = waitForCodexProcessExit(child, { timeoutMs: 100 })
  let settled = false
  exit.finally(() => { settled = true })

  child.emit('error', failure)
  await microtask()
  assert.equal(settled, false, 'only the OS exit event closes the old process generation')
  child.exitCode = 1
  child.emit('exit', 1, null)

  await exit
  assert.equal(child.listenerCount('exit'), 0)
  assert.equal(child.listenerCount('error'), 0)
})
