import assert from 'node:assert/strict'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { spawn } from 'node:child_process'
import test from 'node:test'

import { withCodexMcpConfigLock } from '../src/codex-mcp-config-lock.mjs'

function temporary() {
  return fs.mkdtempSync(path.join(os.tmpdir(), 'codex-mcp-lock-'))
}

function runHolder(directory, holdMs, marker) {
  const modulePath = new URL('../src/codex-mcp-config-lock.mjs', import.meta.url).pathname
  const script = [
    `import fs from 'node:fs'`,
    `import { withCodexMcpConfigLock } from ${JSON.stringify(modulePath)}`,
    `withCodexMcpConfigLock(${JSON.stringify(directory)},()=>{`,
    ` fs.writeFileSync(${JSON.stringify(marker)},'held')`,
    ` Atomics.wait(new Int32Array(new SharedArrayBuffer(4)),0,0,${holdMs})`,
    `})`,
  ].join('\n')
  return spawn(process.execPath, ['--input-type=module', '--eval', script], {
    stdio: ['ignore', 'ignore', 'pipe'],
  })
}

async function waitForFile(file) {
  for (let count = 0; count < 200 && !fs.existsSync(file); count += 1) {
    await new Promise((resolve) => setTimeout(resolve, 5))
  }
  assert.equal(fs.existsSync(file), true)
}

test('a live holder excludes another process until it releases', async (t) => {
  const directory = temporary()
  const marker = path.join(directory, 'holder-ready')
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }))
  const child = runHolder(directory, 120, marker)
  t.after(() => { try { child.kill('SIGKILL') } catch {} })
  await waitForFile(marker)

  assert.throws(() => withCodexMcpConfigLock(directory, () => {}, {
    waitMs: 30, staleMs: 5,
  }), /timed out/)
  await new Promise((resolve) => child.once('exit', resolve))
  assert.doesNotThrow(() => withCodexMcpConfigLock(directory, () => {}))
})

test('the kernel releases a dead holder without pathname recovery', async (t) => {
  const directory = temporary()
  const marker = path.join(directory, 'holder-ready')
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }))
  const child = runHolder(directory, 60_000, marker)
  await waitForFile(marker)
  child.kill('SIGKILL')
  await new Promise((resolve) => child.once('exit', resolve))

  let entered = false
  withCodexMcpConfigLock(directory, () => { entered = true }, {
    waitMs: 1_000,
  })
  assert.equal(entered, true)
})

test('an unsafe lock fails closed', (t) => {
  const directory = temporary()
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }))
  const lock = path.join(directory, '.mechanician-mcp-config.lock')
  fs.writeFileSync(lock, 'not json', { mode: 0o644 })

  assert.throws(() => withCodexMcpConfigLock(directory, () => {}, {
    waitMs: 30,
  }), /unsafe permissions/)
})

test('a symlink lock fails closed', (t) => {
  const directory = temporary()
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }))
  const target = path.join(directory, 'target')
  fs.writeFileSync(target, '', { mode: 0o600 })
  fs.symlinkSync(target, path.join(directory, '.mechanician-mcp-config.lock'))

  assert.throws(
    () => withCodexMcpConfigLock(directory, () => {}, { waitMs: 30 }),
    /ELOOP|symbolic link|too many levels/i,
  )
})

test('a multiply linked lock fails closed', (t) => {
  const directory = temporary()
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }))
  const lock = path.join(directory, '.mechanician-mcp-config.lock')
  fs.writeFileSync(lock, '', { mode: 0o600 })
  fs.linkSync(lock, path.join(directory, 'second-link'))

  assert.throws(
    () => withCodexMcpConfigLock(directory, () => {}, { waitMs: 30 }),
    /not a private regular file/,
  )
})
