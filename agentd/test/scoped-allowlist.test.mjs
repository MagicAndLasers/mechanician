import assert from 'node:assert/strict'
import { spawn } from 'node:child_process'
import { once } from 'node:events'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { test } from 'node:test'
import { ScopedAllowlist, withFileLock } from '../src/scoped-allowlist.mjs'

test('remembered approvals survive relaunch only for the same provider route and workspace', (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'mechanician-scoped-allowlist-'))
  const workspaceA = path.join(root, 'workspace-a')
  const workspaceB = path.join(root, 'workspace-b')
  fs.mkdirSync(workspaceA)
  fs.mkdirSync(workspaceB)
  t.after(() => fs.rmSync(root, { recursive: true, force: true }))

  const codex = new ScopedAllowlist({
    rootDir: root, provider: 'codex', authMode: 'subscription',
  })
  codex.add('Bash', workspaceA)
  assert.deepEqual(codex.snapshot(workspaceA), ['Bash'])
  assert.deepEqual(codex.snapshot(workspaceB), [])

  // Reconstructing the store models an app/daemon relaunch.
  const relaunchedCodex = new ScopedAllowlist({
    rootDir: root, provider: 'codex', authMode: 'subscription',
  })
  assert.equal(relaunchedCodex.has('Bash', workspaceA), true)
  assert.equal(relaunchedCodex.has('Bash', workspaceB), false)

  const claude = new ScopedAllowlist({
    rootDir: root, provider: 'anthropic', authMode: 'subscription',
  })
  assert.equal(claude.has('Bash', workspaceA), false)
  claude.add('Read', workspaceA)
  assert.deepEqual(claude.snapshot(workspaceA), ['Read'])
  assert.deepEqual(relaunchedCodex.snapshot(workspaceA), ['Bash'])

  relaunchedCodex.remove('Bash', workspaceA)
  assert.deepEqual(relaunchedCodex.snapshot(workspaceA), [])
  assert.deepEqual(claude.snapshot(workspaceA), ['Read'])
})

test('simultaneous provider daemons merge remembered approvals instead of clobbering them', async (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'mechanician-scoped-allowlist-race-'))
  const workspace = path.join(root, 'workspace')
  fs.mkdirSync(workspace)
  t.after(() => fs.rmSync(root, { recursive: true, force: true }))

  const moduleURL = new URL('../src/scoped-allowlist.mjs', import.meta.url).href
  const source = `
    import { ScopedAllowlist } from ${JSON.stringify(moduleURL)};
    const store = new ScopedAllowlist({ rootDir: process.env.TEST_ROOT, provider: 'anthropic', authMode: 'apikey' });
    store.add(process.env.TEST_TOOL, process.env.TEST_WORKSPACE);
  `
  const tools = Array.from({ length: 12 }, (_, index) => `Tool-${index}`)
  const children = tools.map((tool) => spawn(process.execPath, ['--input-type=module', '-e', source], {
    env: { ...process.env, TEST_ROOT: root, TEST_WORKSPACE: workspace, TEST_TOOL: tool },
    stdio: ['ignore', 'pipe', 'pipe'],
  }))
  const exits = await Promise.all(children.map((child) => once(child, 'exit')))
  assert.deepEqual(exits.map(([code, signal]) => [code, signal]), tools.map(() => [0, null]))

  const store = new ScopedAllowlist({ rootDir: root, provider: 'anthropic', authMode: 'apikey' })
  assert.deepEqual(store.snapshot(workspace), [...tools].sort())
})

test('withFileLock refuses to steal a fresh lock whose owner reads as dead (no blind unlink)', () => {
  // Deterministic regression for the lost-update race. The pre-fix recovery blind-unlinked a lock
  // the instant it read a dead owner pid — even a lock a live process had just acquired — which let
  // a second holder in and dropped an approval. The fix reaps only after a grace window, so a fresh
  // lock is never stolen. Planted lock: dead owner pid, fresh mtime. Fixed code must refuse to
  // acquire within a sub-grace timeout (throws); the pre-fix code stole it immediately.
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'mechanician-scoped-allowlist-reap-'))
  const file = path.join(root, 'grant.json')
  const lockFile = `${file}.lock`
  fs.writeFileSync(lockFile, JSON.stringify({ version: 1, pid: 999_999, token: 'stale' }))
  assert.throws(
    () => withFileLock(file, () => { throw new Error('must not acquire a fresh live-looking lock') }, 400),
    /timed out locking/)
  assert.ok(fs.existsSync(lockFile), 'the fresh lock must be left intact, not blind-unlinked')
  fs.rmSync(root, { recursive: true, force: true })
})

test('withFileLock still reaps a genuinely stale lock so a crashed holder cannot wedge it', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'mechanician-scoped-allowlist-reap-'))
  const file = path.join(root, 'grant.json')
  const lockFile = `${file}.lock`
  fs.writeFileSync(lockFile, JSON.stringify({ version: 1, pid: 999_999, token: 'stale' }))
  const aged = new Date(Date.now() - 5_000)          // well past the reap grace
  fs.utimesSync(lockFile, aged, aged)
  let ran = false
  withFileLock(file, () => { ran = true }, 3_000)
  assert.ok(ran, 'a dead, aged-out lock must be reaped so acquisition can proceed')
  assert.ok(!fs.existsSync(lockFile), 'the lock must be released after the critical section')
  fs.rmSync(root, { recursive: true, force: true })
})
