import assert from 'node:assert/strict'
import test from 'node:test'

import {
  codexMcpActivationState,
  mergeCodexLiveStatus,
  recordCodexStartupStatus,
} from '../src/codex-mcp-status.mjs'

const configured = (names) => names.map((name) => ({ name, status: 'configured', tools: null }))

test('a mounted server reports connected with its tool count', () => {
  const [row] = mergeCodexLiveStatus(configured(['bridge']), {
    listData: [{
      name: 'bridge',
      serverInfo: { name: 'mechanician-mac-bridge', version: '0.1.0' },
      tools: { a: {}, b: {}, c: {} },
      authStatus: 'oAuth',
    }],
  })

  assert.equal(row.status, 'connected')
  assert.equal(row.tools, 3)
})

/// The one failure a user can act on directly, so it must not collapse into a generic "failed".
test('reauthenticationRequired becomes needs-auth, not failed', () => {
  const startup = recordCodexStartupStatus(new Map(), {
    name: 'bridge', status: 'failed', failureReason: 'reauthenticationRequired',
  })

  const [row] = mergeCodexLiveStatus(configured(['bridge']), { startup })

  assert.equal(row.status, 'needs-auth')
  assert.equal(row.error, null)
})

test('a server that has never logged in reports needs-auth', () => {
  const [row] = mergeCodexLiveStatus(configured(['bridge']), {
    listData: [{ name: 'bridge', serverInfo: null, tools: {}, authStatus: 'notLoggedIn' }],
  })

  assert.equal(row.status, 'needs-auth')
})

test('a startup failure carries the reason Codex gave', () => {
  const startup = recordCodexStartupStatus(new Map(), {
    name: 'bridge', status: 'failed', error: 'connection refused',
  })

  const [row] = mergeCodexLiveStatus(configured(['bridge']), { startup })

  assert.equal(row.status, 'failed')
  assert.equal(row.error, 'connection refused')
})

test('starting and cancelled map to pending and failed', () => {
  const starting = recordCodexStartupStatus(new Map(), { name: 'bridge', status: 'starting' })
  assert.equal(mergeCodexLiveStatus(configured(['bridge']), { startup: starting })[0].status, 'pending')

  const cancelled = recordCodexStartupStatus(new Map(), { name: 'bridge', status: 'cancelled' })
  assert.equal(mergeCodexLiveStatus(configured(['bridge']), { startup: cancelled })[0].status, 'failed')
})

/// A notification is newer than the list snapshot, so a failure must not be masked by a stale
/// "it was connected a moment ago".
test('a later startup notification wins over the list snapshot', () => {
  const startup = recordCodexStartupStatus(new Map(), {
    name: 'bridge', status: 'failed', error: 'went away',
  })

  const [row] = mergeCodexLiveStatus(configured(['bridge']), {
    listData: [{ name: 'bridge', serverInfo: { name: 'x' }, tools: { a: {} }, authStatus: 'oAuth' }],
    startup,
  })

  assert.equal(row.status, 'failed')
  assert.equal(row.error, 'went away')
})

/// We know exactly why these are absent. Reporting "unknown" would turn a fixable message into a
/// mystery — the user would see a server they configured simply not being there.
test('a server Codex could not be given reports why', () => {
  const [row] = mergeCodexLiveStatus(configured(['legacy']), {
    unsupported: [{ name: 'legacy', reason: 'SSE is not supported.' }],
  })

  assert.equal(row.status, 'failed')
  assert.match(row.error, /SSE is not supported/)
})

test('a configured server Codex has not reported on yet is pending, never connected', () => {
  const [row] = mergeCodexLiveStatus(configured(['bridge']), {})

  assert.equal(row.status, 'pending')
  assert.equal(row.tools, null)
})

test('every configured server yields exactly one row, in order', () => {
  const rows = mergeCodexLiveStatus(configured(['a', 'b', 'c']), {
    listData: [{ name: 'b', serverInfo: { name: 'b' }, tools: {}, authStatus: 'oAuth' }],
  })

  assert.deepEqual(rows.map((r) => r.name), ['a', 'b', 'c'])
  assert.equal(rows[1].status, 'connected')
})

test('only the newest notification per server is kept', () => {
  const store = new Map()
  recordCodexStartupStatus(store, { name: 'bridge', status: 'starting' })
  recordCodexStartupStatus(store, { name: 'bridge', status: 'ready' })

  assert.equal(store.size, 1)
  assert.equal(store.get('bridge').status, 'ready')
  assert.equal(mergeCodexLiveStatus(configured(['bridge']), { startup: store })[0].status, 'connected')
})

test('activation waits for a positive agent-visible tool inventory', () => {
  assert.equal(codexMcpActivationState('bridge', {
    listData: [{ name: 'bridge', serverInfo: { name: 'bridge' }, authStatus: 'oAuth' }],
  }).terminal, false, 'handshake without tools/list is not ready')

  assert.equal(codexMcpActivationState('bridge', {
    listData: [{
      name: 'bridge', serverInfo: { name: 'bridge' }, authStatus: 'oAuth', tools: {},
    }],
  }).terminal, false,
  'zero tools cannot prove the reported post-auth problem is fixed')

  assert.deepEqual(codexMcpActivationState('bridge', {
    listData: [{
      name: 'bridge', serverInfo: { name: 'bridge' }, authStatus: 'oAuth',
      tools: { search: {} },
    }],
  }), { terminal: true, ok: true, status: 'connected', tools: 1, error: null })
})

test('activation surfaces terminal authentication and startup failures', () => {
  assert.equal(codexMcpActivationState('bridge', {
    listData: [{ name: 'bridge', authStatus: 'notLoggedIn', tools: {} }],
  }).status, 'needs-auth')
  assert.deepEqual(codexMcpActivationState('bridge', {
    startup: new Map([['bridge', { status: 'failed', error: 'connection refused' }]]),
  }), {
    terminal: true, ok: false, status: 'failed', error: 'connection refused',
  })
})

/// A measured Codex transport error ran past 300 characters of Rust type machinery before reaching
/// anything a person can act on, and it lands in a panel row.
test('a long transport error is trimmed to something a row can show', () => {
  const startup = recordCodexStartupStatus(new Map(), {
    name: 'bridge',
    status: 'failed',
    error: 'MCP startup failed: ' + 'rmcp::transport::worker::WorkerTransport<x>'.repeat(20),
  })

  const [row] = mergeCodexLiveStatus(configured(['bridge']), { startup })

  assert.ok(row.error.length <= 200, `was ${row.error.length}`)
  assert.match(row.error, /^MCP startup failed:/, 'keeps the readable head')
  assert.match(row.error, /…$/)
})
