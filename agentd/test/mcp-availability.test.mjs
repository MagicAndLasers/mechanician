import assert from 'node:assert/strict'
import { test } from 'node:test'

import { createMCPAvailabilityChecker } from '../src/mcp-availability.mjs'

function fixture() {
  return {
    servers: {
      public: { type: 'http', url: 'https://public.example/mcp', headers: {} },
      internal: { type: 'http', url: 'https://internal.acme.example/mcp', headers: { Authorization: 'secret' } },
      local: { type: 'stdio', command: '/bin/example', args: [], env: {} },
    },
    networkScopes: { public: 'public', internal: 'vpnOnly', local: 'vpnOnly' },
    plugins: [],
    errors: [],
  }
}

test('an unreachable VPN-only remote is omitted without affecting public or stdio servers', async () => {
  const calls = []
  const checker = createMCPAvailabilityChecker({
    fetchImpl: async (url, options) => {
      calls.push({ url: String(url), options })
      throw new TypeError('network route unavailable')
    },
  })

  const result = await checker.filter(fixture())

  assert.deepEqual(Object.keys(result.servers).sort(), ['local', 'public'])
  assert.deepEqual(result.unavailable, [{
    name: 'internal',
    message: 'VPN-only MCP server unavailable — connect to your corporate VPN.',
  }])
  assert.equal(calls.length, 1)
  assert.equal(calls[0].url, 'https://internal.acme.example/mcp')
  assert.equal(calls[0].options.method, 'HEAD')
  assert.equal(calls[0].options.headers.Authorization, undefined,
    'the reachability probe must not transmit configured MCP credentials')
})

test('a proxy or service 5xx is unavailable even though an HTTP route answered', async () => {
  const checker = createMCPAvailabilityChecker({ fetchImpl: async () => ({ status: 502 }) })
  const result = await checker.filter(fixture())
  assert.equal(result.servers.internal, undefined)
  assert.equal(result.unavailable.length, 1)
})

test('any HTTP response proves VPN reachability and results are cached briefly', async () => {
  let calls = 0
  let now = 1_000
  const checker = createMCPAvailabilityChecker({
    fetchImpl: async () => { calls += 1; return { status: 401 } },
    now: () => now,
    cacheTTLms: 30_000,
  })

  const first = await checker.filter(fixture())
  const second = await checker.filter(fixture())
  assert.ok(first.servers.internal)
  assert.ok(second.servers.internal)
  assert.equal(calls, 1)

  now += 30_001
  await checker.filter(fixture())
  assert.equal(calls, 2)
})

test('reachable routes stay warm while VPN failures retry quickly', async () => {
  let calls = 0
  let now = 1_000
  let status = 401
  const checker = createMCPAvailabilityChecker({
    fetchImpl: async () => { calls += 1; return { status } },
    now: () => now,
    reachableCacheTTLms: 300_000,
    unreachableCacheTTLms: 15_000,
  })

  assert.ok((await checker.filter(fixture())).servers.internal)
  now += 60_000
  assert.ok((await checker.filter(fixture())).servers.internal)
  assert.equal(calls, 1, 'ordinary think time between prompts should not re-probe a healthy VPN')

  checker.clearCache()
  status = 503
  assert.equal((await checker.filter(fixture())).servers.internal, undefined)
  now += 14_999
  assert.equal((await checker.filter(fixture())).servers.internal, undefined)
  assert.equal(calls, 2)
  now += 2
  status = 401
  assert.ok((await checker.filter(fixture())).servers.internal)
  assert.equal(calls, 3, 'a restored VPN is retried after the short negative TTL')
})

test('public servers never receive a speculative reachability request', async () => {
  let calls = 0
  const checker = createMCPAvailabilityChecker({ fetchImpl: async () => { calls += 1; return {} } })
  const loaded = fixture()
  loaded.networkScopes.internal = 'public'

  const result = await checker.filter(loaded)

  assert.deepEqual(Object.keys(result.servers).sort(), ['internal', 'local', 'public'])
  assert.deepEqual(result.unavailable, [])
  assert.equal(calls, 0)
})
