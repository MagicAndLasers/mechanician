import assert from 'node:assert/strict'
import { test } from 'node:test'

import {
  DEFAULT_MCP_TURN_READINESS_TIMEOUT_MS,
  eagerMcpServerNames,
  waitForMcpTurnReadiness,
} from '../src/mcp-turn-readiness.mjs'

test('promoted post-auth readiness has a bounded thirty-second default', () => {
  assert.equal(DEFAULT_MCP_TURN_READINESS_TIMEOUT_MS, 30_000)
})

test('readiness polling aborts immediately with the owning turn', async () => {
  const controller = new AbortController()
  let statusCalls = 0
  const pending = waitForMcpTurnReadiness(
    { mcpServerStatus: async () => {
      statusCalls += 1
      return new Promise(() => {})
    } },
    ['VICE'],
    { signal: controller.signal, timeoutMs: 30_000, controlTimeoutMs: 30_000 },
  )

  controller.abort(new Error('stopped'))

  await assert.rejects(pending, /stopped/)
  assert.equal(statusCalls, 1)
})

test('only explicitly eager external MCP servers can gate the first prompt', () => {
  assert.deepEqual(eagerMcpServerNames({
    deferred: { type: 'http', url: 'https://example.com' },
    eager: { type: 'stdio', command: 'example', alwaysLoad: true },
    falseIsDeferred: { type: 'http', url: 'https://example.org', alwaysLoad: false },
  }), ['eager'])
})

test('real-turn readiness waits for configured tools to mount', async () => {
  const snapshots = [
    [{ name: 'VICE', status: 'pending' }],
    [{ name: 'VICE', status: 'connected', tools: [{ name: 'whoami' }, { name: 'list' }] }],
  ]
  const result = await waitForMcpTurnReadiness(
    { mcpServerStatus: async () => snapshots.shift() },
    ['VICE'],
    { timeoutMs: 100, pollIntervalMs: 1, controlTimeoutMs: 20 },
  )
  assert.deepEqual(result, [{
    name: 'VICE', status: 'connected', tools: 2, error: null,
  }])
})

test('readiness reports deduplicated aggregate progress snapshots', async () => {
  const progress = []
  const snapshots = [
    [{ name: 'one', status: 'pending' }, { name: 'two', status: 'pending' }],
    [{ name: 'one', status: 'connected', tools: [{ name: 'a' }] },
      { name: 'two', status: 'pending' }],
    [{ name: 'one', status: 'connected', tools: [{ name: 'a' }] },
      { name: 'two', status: 'connected', tools: [] }],
  ]
  await waitForMcpTurnReadiness(
    { mcpServerStatus: async () => snapshots.shift() },
    ['one', 'two'],
    {
      timeoutMs: 100, pollIntervalMs: 1, controlTimeoutMs: 20,
      onSnapshot: (snapshot) => progress.push(snapshot.map((entry) => entry.status)),
    },
  )
  assert.deepEqual(progress, [
    ['pending', 'pending'],
    ['connected', 'pending'],
    ['connected', 'connected'],
  ])
})

test('a terminal auth failure does not hold the user prompt until timeout', async () => {
  let calls = 0
  const result = await waitForMcpTurnReadiness(
    { mcpServerStatus: async () => {
      calls++
      return [{ name: 'VICE', status: 'needs-auth' }]
    } },
    ['VICE'],
    { timeoutMs: 100, pollIntervalMs: 1, controlTimeoutMs: 20 },
  )
  assert.equal(calls, 1)
  assert.equal(result[0].status, 'needs-auth')
})

test('an authenticated server remains truthful when provider status never settles', async () => {
  let clock = 0
  const result = await waitForMcpTurnReadiness(
    { mcpServerStatus: async () => [{ name: 'VICE', status: 'pending' }] },
    ['VICE'],
    {
      authorizationStates: { VICE: 'authenticated' },
      timeoutMs: 2,
      pollIntervalMs: 1,
      controlTimeoutMs: 1,
      now: () => ++clock,
    },
  )
  assert.equal(result[0].status, 'pending')
  assert.equal(result[0].tools, null)
})
