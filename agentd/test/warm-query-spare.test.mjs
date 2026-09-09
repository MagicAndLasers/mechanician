import test from 'node:test'
import assert from 'node:assert/strict'
import { createWarmQuerySpare } from '../src/warm-query-spare.mjs'

test('a matching claim transfers the prepared one-shot query', async () => {
  let closes = 0
  const cache = createWarmQuerySpare()
  cache.warm('conversation-a', async () => ({
    value: 42,
    close() { closes++ },
  }))

  const claimed = await cache.claim('conversation-a')
  assert.equal(claimed.value, 42)
  assert.equal(cache.pending, false)
  cache.clear()
  assert.equal(closes, 0, 'the caller owns a claimed query')
  claimed.close()
  assert.equal(closes, 1)
})

test('warming the same configuration deduplicates in-flight preparation', async () => {
  let preparations = 0
  let release
  const cache = createWarmQuerySpare()
  const first = cache.warm('same', async () => {
    preparations++
    await new Promise((resolve) => { release = resolve })
    return { close() {} }
  })
  const second = cache.warm('same', async () => {
    preparations++
    return { close() {} }
  })

  assert.equal(first, second)
  await new Promise((resolve) => setImmediate(resolve))
  assert.equal(preparations, 1)
  release()
  await first
  cache.clear()
})

test('a mismatched claim closes an in-flight spare once it finishes', async () => {
  let closes = 0
  let release
  const cache = createWarmQuerySpare()
  const prepared = cache.warm('old', async () => {
    await new Promise((resolve) => { release = resolve })
    return { close() { closes++ } }
  })
  await new Promise((resolve) => setImmediate(resolve))

  assert.equal(await cache.claim('new'), null)
  release()
  await prepared
  await new Promise((resolve) => setImmediate(resolve))
  assert.equal(closes, 1)
  assert.equal(cache.pending, false)
})

test('replacing a ready spare closes the superseded process', async () => {
  let oldCloses = 0
  const cache = createWarmQuerySpare()
  await cache.warm('old', async () => ({ close() { oldCloses++ } }))
  cache.warm('new', async () => ({ close() {} }))
  await new Promise((resolve) => setImmediate(resolve))

  assert.equal(oldCloses, 1)
  cache.clear()
})

test('an unused prepared process expires instead of living for the daemon lifetime', async () => {
  let closes = 0
  const cache = createWarmQuerySpare({ maxIdleMs: 5 })
  await cache.warm('idle', async () => ({ close() { closes++ } }))

  await new Promise((resolve) => setTimeout(resolve, 20))
  assert.equal(cache.pending, false)
  assert.equal(closes, 1)
})
