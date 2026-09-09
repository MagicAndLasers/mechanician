import assert from 'node:assert/strict'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { spawn } from 'node:child_process'
import test from 'node:test'

import {
  CODEX_PROACTIVE_REFRESH_INTERVAL_MS,
  claimCodexProactiveRefresh,
} from '../src/codex-auth-refresh-lease.mjs'

function temporary(t) {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'codex-auth-lease-'))
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }))
  return directory
}

test('only the first daemon in a burst is told to rotate the grant', (t) => {
  const home = temporary(t)
  let clock = 1_000_000
  const claim = () => claimCodexProactiveRefresh(home, { now: () => clock })

  // Three daemons starting in the same instant is the ordinary case when a lane restarts, and it
  // is what rotated one single-use refresh token three times and produced `refresh_token_reused`.
  assert.equal(claim(), true)
  assert.equal(claim(), false)
  assert.equal(claim(), false)
})

test('a lane that starts after the interval may rotate again', (t) => {
  const home = temporary(t)
  let clock = 1_000_000
  assert.equal(claimCodexProactiveRefresh(home, { now: () => clock }), true)

  clock += CODEX_PROACTIVE_REFRESH_INTERVAL_MS - 1
  assert.equal(claimCodexProactiveRefresh(home, { now: () => clock }), false)

  clock += 1
  assert.equal(claimCodexProactiveRefresh(home, { now: () => clock }), true)
})

test('a timestamp from the future does not suppress refresh until real time catches up', (t) => {
  const home = temporary(t)
  assert.equal(claimCodexProactiveRefresh(home, { now: () => 9_000_000 }), true)

  // A clock change or a torn write must not leave the lane unable to refresh for hours.
  assert.equal(claimCodexProactiveRefresh(home, { now: () => 1_000 }), true)
})

test('a corrupt lease is claimable rather than fatal', (t) => {
  const home = temporary(t)
  fs.writeFileSync(path.join(home, '.mechanician-auth-refresh.lock'), 'not json', { mode: 0o600 })
  assert.equal(claimCodexProactiveRefresh(home, { now: () => 1_000_000 }), true)
})

test('the lease is created inside a CODEX_HOME that does not exist yet', (t) => {
  const home = path.join(temporary(t), 'nested', 'codex')
  assert.equal(claimCodexProactiveRefresh(home, { now: () => 1_000_000 }), true)
  assert.equal(fs.existsSync(path.join(home, '.mechanician-auth-refresh.lock')), true)
})

test('a live holder in another process is not asked to share the rotation', async (t) => {
  const home = temporary(t)
  const ready = path.join(home, 'holder-ready')
  const modulePath = new URL('../src/codex-home-lock.mjs', import.meta.url).pathname
  const lockPath = path.join(home, '.mechanician-auth-refresh.lock')
  const script = [
    `import fs from 'node:fs'`,
    `import { openExclusiveLock } from ${JSON.stringify(modulePath)}`,
    `openExclusiveLock(${JSON.stringify(lockPath)})`,
    `fs.writeFileSync(${JSON.stringify(ready)},'held')`,
    `Atomics.wait(new Int32Array(new SharedArrayBuffer(4)),0,0,400)`,
  ].join('\n')
  const child = spawn(process.execPath, ['--input-type=module', '--eval', script], {
    stdio: ['ignore', 'ignore', 'pipe'],
  })
  t.after(() => child.kill('SIGKILL'))
  for (let count = 0; count < 200 && !fs.existsSync(ready); count += 1) {
    await new Promise((resolve) => setTimeout(resolve, 5))
  }
  assert.equal(fs.existsSync(ready), true)

  // Contention means someone else is mid-refresh, not that this start failed. The caller still
  // gets a working account read; it just does not rotate the grant a second time.
  assert.equal(claimCodexProactiveRefresh(home, { now: () => 1_000_000 }), false)
})
