import assert from 'node:assert/strict'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { test } from 'node:test'
import { createBuildScheduler } from '../src/build-scheduler.mjs'

// A fake "build" the scheduler orders: schedule() runs start(), which records a proc and returns a
// finish() it can call to simulate the child closing.
function fakeBuild(scheduler, root, log) {
  const proc = { root, killed: false }
  scheduler.schedule(root, () => {
    scheduler.setProc(root, proc)
    log.push(`start:${root}`)
  })
  return { proc, done: () => { log.push(`done:${root}`); scheduler.finish(root) } }
}

test('builds at different roots run concurrently', () => {
  const s = createBuildScheduler()
  const log = []
  fakeBuild(s, '/a', log)
  fakeBuild(s, '/b', log)
  assert.deepEqual(log, ['start:/a', 'start:/b'])
  assert.deepEqual(s.activeRoots().sort(), ['/a', '/b'])
})

test('a second build at the SAME root queues, then runs when the first finishes', () => {
  const s = createBuildScheduler()
  const log = []
  const first = fakeBuild(s, '/a', log)
  const second = fakeBuild(s, '/a', log)      // queued, not started
  assert.deepEqual(log, ['start:/a'])
  assert.equal(s.queueDepth('/a'), 1)
  first.done()                                 // first closes → second starts
  assert.deepEqual(log, ['start:/a', 'done:/a', 'start:/a'])
  assert.equal(s.queueDepth('/a'), 0)
  second.done()
  assert.equal(s.isActive('/a'), false)
})

test('queued builds at one root run in FIFO order', () => {
  const s = createBuildScheduler()
  const order = []
  const root = '/r'
  const mk = (n) => s.schedule(root, () => { s.setProc(root, { n }); order.push(n) })
  mk(1); mk(2); mk(3)                          // 1 starts, 2 & 3 queue
  assert.deepEqual(order, [1])
  s.finish(root); assert.deepEqual(order, [1, 2])
  s.finish(root); assert.deepEqual(order, [1, 2, 3])
  s.finish(root); assert.equal(s.isActive(root), false)
})

test('finishing an idle/unknown root is a no-op', () => {
  const s = createBuildScheduler()
  assert.doesNotThrow(() => s.finish('/nope'))
})

test('cancel(root) signals the active build and drops its queue so nothing starts after', () => {
  const signalled = []
  const s = createBuildScheduler({ signal: (proc, sig) => signalled.push([proc.root, sig]) })
  const log = []
  const first = fakeBuild(s, '/a', log)
  fakeBuild(s, '/a', log)                       // queued
  fakeBuild(s, '/b', log)                       // unrelated root, must be untouched
  s.cancel('/a')
  assert.deepEqual(signalled, [['/a', 'SIGTERM']])
  assert.equal(s.queueDepth('/a'), 0)           // queued build dropped
  // The real child's close still calls finish(); with an empty queue nothing new starts.
  first.done()
  assert.deepEqual(log, ['start:/a', 'start:/b', 'done:/a'])
  assert.equal(s.isActive('/b'), true)          // /b untouched
})

test('cancel(null) cancels every active root (build_cancel carries no cwd)', () => {
  const signalled = []
  const s = createBuildScheduler({ signal: (proc, sig) => signalled.push([proc.root, sig]) })
  const log = []
  fakeBuild(s, '/a', log)
  fakeBuild(s, '/b', log)
  s.cancel(null)
  assert.deepEqual(signalled.map(x => x[0]).sort(), ['/a', '/b'])
})

test('stopAll signals all active builds and clears every queue', () => {
  const signalled = []
  const s = createBuildScheduler({ signal: (proc, sig) => signalled.push([proc.root, sig]) })
  const log = []
  fakeBuild(s, '/a', log)
  fakeBuild(s, '/a', log)   // queued
  fakeBuild(s, '/b', log)
  s.stopAll('SIGKILL')
  assert.deepEqual(signalled.map(x => x[1]), ['SIGKILL', 'SIGKILL'])   // one per ACTIVE root
  assert.equal(s.queueDepth('/a'), 0)
})

test('rootFor resolves realpath and shares a slot for symlinked paths', (t) => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'mech-build-root-'))
  const real = path.join(dir, 'real'); fs.mkdirSync(real)
  const link = path.join(dir, 'link'); fs.symlinkSync(real, link)
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }))
  const s = createBuildScheduler()
  assert.equal(s.rootFor(link), s.rootFor(real), 'symlink and target must key to the same root')
})

test('rootFor falls back to a lexical path when the directory does not exist', () => {
  const s = createBuildScheduler()
  const missing = '/definitely/not/here/xyz'
  assert.equal(s.rootFor(missing), path.resolve(missing))
})

test('rootFor uses the fallback when dir is empty', () => {
  const s = createBuildScheduler()
  assert.equal(s.rootFor('', os.tmpdir()), s.rootFor(os.tmpdir()))
})
