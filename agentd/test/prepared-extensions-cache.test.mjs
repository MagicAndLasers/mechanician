import assert from 'node:assert/strict'
import { test } from 'node:test'

import { createPreparedExtensionsCache } from '../src/prepared-extensions-cache.mjs'

test('secure preparation is shared and reused while the extension fingerprint is unchanged', async () => {
  let key = 'one'
  let loads = 0
  let preparations = 0
  let release
  const gate = new Promise((resolve) => { release = resolve })
  const cache = createPreparedExtensionsCache({
    fingerprint: () => key,
    load: async () => { loads++; await gate; return { servers: { work: {} } } },
    prepare: async (value) => { preparations++; value.ready = true; return value },
  })

  const first = cache.get()
  const second = cache.get()
  release()
  const [a, b] = await Promise.all([first, second])
  assert.equal(loads, 1)
  assert.equal(preparations, 1)
  assert.deepEqual(a, b)
  a.servers.work.changed = true
  assert.equal(b.servers.work.changed, undefined, 'callers receive isolated snapshots')

  await cache.get()
  assert.equal(loads, 1)
  key = 'two'
  await cache.get()
  assert.equal(loads, 2)
})

test('explicit invalidation prevents a stale in-flight preparation from repopulating the cache', async () => {
  let loads = 0
  let release
  const gate = new Promise((resolve) => { release = resolve })
  const cache = createPreparedExtensionsCache({
    fingerprint: () => 'same',
    load: async () => {
      loads++
      if (loads === 1) await gate
      return { loads }
    },
    prepare: async (value) => value,
  })

  const stale = cache.get()
  await Promise.resolve()
  cache.invalidate()
  release()
  await stale
  assert.equal((await cache.get()).loads, 2)
})
