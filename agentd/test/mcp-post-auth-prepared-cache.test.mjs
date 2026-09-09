import assert from 'node:assert/strict'
import { test } from 'node:test'

import { createPreparedExtensionsCache } from '../src/prepared-extensions-cache.mjs'

function deferred() {
  let resolve
  const promise = new Promise((done) => { resolve = done })
  return { promise, resolve }
}

test('the first post-auth request replaces an in-flight pre-auth extension snapshot', async () => {
  const oldPreparation = deferred()
  let authenticated = false
  let loads = 0
  const cache = createPreparedExtensionsCache({
    // OAuth credentials live outside extensions.json, so its fingerprint deliberately stays the
    // same across this transition. Explicit invalidation is the only generation boundary.
    fingerprint: () => 'unchanged-extensions-file',
    load: async () => {
      loads++
      const loadAuthenticated = authenticated
      if (loads === 1) await oldPreparation.promise
      return {
        authorizationStates: { VICE: loadAuthenticated ? 'authenticated' : 'needs-auth' },
        servers: loadAuthenticated ? { VICE: { type: 'http' } } : {},
      }
    },
    prepare: async (loaded) => loaded,
  })

  const preAuth = cache.get()
  await Promise.resolve()

  authenticated = true
  cache.invalidate()
  const firstPostAuth = cache.get()
  const concurrentPostAuth = cache.get()

  assert.deepEqual(await firstPostAuth, {
    authorizationStates: { VICE: 'authenticated' },
    servers: { VICE: { type: 'http' } },
  })
  assert.deepEqual(await concurrentPostAuth, {
    authorizationStates: { VICE: 'authenticated' },
    servers: { VICE: { type: 'http' } },
  })
  assert.equal(loads, 2, 'post-auth callers share exactly one replacement preparation')

  oldPreparation.resolve()
  assert.deepEqual(await preAuth, {
    authorizationStates: { VICE: 'needs-auth' },
    servers: {},
  })
  assert.deepEqual(await cache.get(), {
    authorizationStates: { VICE: 'authenticated' },
    servers: { VICE: { type: 'http' } },
  }, 'the late pre-auth result must not overwrite the replacement generation')
  assert.equal(loads, 2)
})

test('post-auth callers receive isolated copies of the replacement tool snapshot', async () => {
  let authenticated = false
  let loads = 0
  const cache = createPreparedExtensionsCache({
    fingerprint: () => 'unchanged-extensions-file',
    load: async () => {
      loads++
      return authenticated
        ? { servers: { VICE: { tools: ['search'] } } }
        : { servers: {} }
    },
    prepare: async (loaded) => loaded,
  })

  assert.deepEqual(await cache.get(), { servers: {} })
  authenticated = true
  cache.invalidate()

  const first = await cache.get()
  first.servers.VICE.tools.push('test-only-mutation')
  const second = await cache.get()

  assert.deepEqual(second, { servers: { VICE: { tools: ['search'] } } })
  assert.equal(loads, 2)
})
