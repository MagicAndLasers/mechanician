// Trigger baselines and schedule arithmetic, verified against the REAL daemon process.
//
// These cover the two ambient findings from the 2026-07-18 audit that could fire an unattended,
// full-access agent turn nobody asked for (#7) or run a task hours from when the UI says it will
// (#16). Both were fixed at review level only; this is the live pass.
//
// The #7 scenario is compressed into startup state rather than driven through a 30-second tick:
// an app-side edit changes the task's definition revision, so "the user renamed a task while the
// daemon held a watermark" is exactly "runtime.json holds state stamped with a DIFFERENT revision
// than the task now has". That is assertable on the daemon's first tick.

import assert from 'node:assert/strict'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { spawn } from 'node:child_process'
import { once } from 'node:events'
import { fileURLToPath } from 'node:url'
import { test } from 'node:test'

const here = path.dirname(fileURLToPath(import.meta.url))
const ambientd = path.resolve(here, '../src/ambientd.mjs')

async function waitFor(predicate, description, timeout = 10_000) {
  const deadline = Date.now() + timeout
  while (Date.now() < deadline) {
    const value = predicate()
    if (value) return value
    await new Promise((resolve) => setTimeout(resolve, 20))
  }
  assert.fail(`timed out waiting for ${description}`)
}

function readJSON(file) {
  try { return JSON.parse(fs.readFileSync(file, 'utf8')) } catch { return null }
}

/// A stand-in for the agent SDK so a firing task completes without a network call or a credential.
function writeFakeSDKLoader(support) {
  const sdkSource = `
    export function createSdkMcpServer(config) { return config }
    export function tool(name, description, schema, handler) { return { name, description, schema, handler } }
    export async function* query() {
      yield { type: 'assistant', message: { content: [{ type: 'text', text: 'fixture result' }] } }
    }
  `
  const sdkURL = `data:text/javascript;base64,${Buffer.from(sdkSource).toString('base64')}`
  fs.writeFileSync(path.join(support, 'fake-sdk-hooks.mjs'), `
    const sdkURL = ${JSON.stringify(sdkURL)}
    export async function resolve(specifier, context, nextResolve) {
      if (specifier === '@anthropic-ai/claude-agent-sdk') return { url: sdkURL, shortCircuit: true }
      return nextResolve(specifier, context)
    }
  `)
  const loader = path.join(support, 'fake-sdk-loader.mjs')
  fs.writeFileSync(loader, `
    import { register } from 'node:module'
    register(new URL('./fake-sdk-hooks.mjs', import.meta.url))
  `)
  return loader
}

function harness(t, prefix) {
  const support = fs.mkdtempSync(path.join(os.tmpdir(), prefix))
  const children = []
  t.after(async () => {
    for (const child of children) if (child.exitCode === null) child.kill('SIGKILL')
    await Promise.all(children.map(async (child) => {
      if (child.exitCode === null) { try { await once(child, 'exit') } catch {} }
    }))
    fs.rmSync(support, { recursive: true, force: true })
  })

  fs.mkdirSync(path.join(support, 'ambient'), { recursive: true })
  fs.mkdirSync(path.join(support, 'workspaces'), { recursive: true })
  // A real workspace id, because the resolver only reads `workspaces/<id>.json` for a well-formed
  // UUID and reports anything else as `unresolved:` — which the scheduler now holds instead of
  // running from the home directory.
  const workspaceID = '0A1B2C3D-4E5F-6A7B-8C9D-0E1F2A3B4C5D'
  fs.writeFileSync(path.join(support, 'workspaces', `${workspaceID}.json`),
    JSON.stringify({ id: workspaceID, cwd: support }))

  return {
    support,
    workspaceID,
    ambientFile: (name) => path.join(support, 'ambient', name),
    writeTasks(list) {
      fs.writeFileSync(path.join(support, 'ambient', 'tasks.json'), JSON.stringify(list, null, 2))
    },
    writeRuntime(map) {
      fs.writeFileSync(path.join(support, 'ambient', 'runtime.json'), JSON.stringify(map, null, 2))
    },
    start() {
      const loader = writeFakeSDKLoader(support)
      const child = spawn(process.execPath, ['--import', loader, ambientd], {
        env: {
          ...process.env,
          MECHANICIAN_SUPPORT_DIR: support,
          MECHANICIAN_AMBIENT_INPROCESS: '1',   // suppress the osascript notification banner
          ANTHROPIC_API_KEY: 'test-only-not-a-key',
          ANTHROPIC_AUTH_TOKEN: '',
          CLAUDE_CODE_OAUTH_TOKEN: '',
        },
        stdio: ['ignore', 'ignore', 'pipe'],
      })
      child.stderr.resume()
      children.push(child)
      return child
    },
  }
}

const baseTask = (over) => ({
  id: over.id,
  name: over.name || 'Fixture',
  prompt: 'Do the fixture thing.',
  workspaceID: over.workspaceID,
  enabled: true,
  trigger: over.trigger,
})

/// A task that fires unconditionally on the first tick, placed LAST in the list.
///
/// Asserting "runs.json is still empty" on its own proves nothing: `claimRun` persists runtime.json
/// BEFORE the run executes, so a test that waits on runtime.json and then reads runs.json can win
/// that race and pass even when the task did fire. The tick loop is sequential and awaits each run,
/// so this sentinel appearing in runs.json is proof the tick has already decided about every task
/// ahead of it — the assertion becomes "the tick ran, and chose not to fire the task under test".
const SENTINEL_ID = 'T-SENTINEL'
const sentinelTask = (workspaceID) => ({
  ...baseTask({ id: SENTINEL_ID, name: 'Barrier', workspaceID,
                trigger: { type: 'file', path: '/nonexistent-so-it-never-triggers' } }),
  runRequestID: 'barrier-request',
})

async function tickCompleted(h) {
  const runs = await waitFor(() => {
    const list = readJSON(h.ambientFile('runs.json'))
    return list?.some((r) => r.taskId === SENTINEL_ID) ? list : null
  }, 'the first tick to finish (sentinel run recorded)')
  return runs.filter((r) => r.taskId !== SENTINEL_ID)
}

// ── #16: a daily schedule fires at the hour the UI shows ────────────────────────────

test('daily at midnight schedules for 00:30, not 09:30', async (t) => {
  const h = harness(t, 'mechanician-ambient-midnight-')
  h.writeTasks([
    baseTask({ id: 'T-MIDNIGHT', name: 'Overnight report', workspaceID: h.workspaceID,
               trigger: { type: 'time', schedule: { kind: 'daily', hour: 0, minute: 30 } } }),
    // Control: the same code path with a non-zero hour. Without it, a regression that ignored the
    // configured hour entirely would still pass the midnight assertion by accident.
    baseTask({ id: 'T-MORNING', name: 'Morning report', workspaceID: h.workspaceID,
               trigger: { type: 'time', schedule: { kind: 'daily', hour: 9, minute: 30 } } }),
    sentinelTask(h.workspaceID),
  ])
  h.start()

  const runtime = await waitFor(() => {
    const r = readJSON(h.ambientFile('runtime.json'))
    return r?.['T-MIDNIGHT']?.nextRun && r?.['T-MORNING']?.nextRun ? r : null
  }, 'both daily tasks to be scheduled')

  const midnight = new Date(runtime['T-MIDNIGHT'].nextRun)
  assert.strictEqual(midnight.getHours(), 0, 'hour 0 must survive as midnight')
  assert.strictEqual(midnight.getMinutes(), 30)

  const morning = new Date(runtime['T-MORNING'].nextRun)
  assert.strictEqual(morning.getHours(), 9)
  assert.strictEqual(morning.getMinutes(), 30)

  // No task is due yet, so nothing may have run.
  assert.deepStrictEqual(await tickCompleted(h), [])
})

// ── #7: an app-side edit rearms baselines instead of firing an unattended run ────────

test('a definition edit rearms a file watermark rather than firing a run', async (t) => {
  const h = harness(t, 'mechanician-ambient-rearm-')
  const watched = path.join(h.support, 'watched.txt')
  fs.writeFileSync(watched, 'current contents')

  h.writeTasks([
    baseTask({ id: 'T-WATCH', name: 'Renamed by the user', workspaceID: h.workspaceID,
               trigger: { type: 'file', path: watched } }),
    sentinelTask(h.workspaceID),
  ])
  // Runtime left by the daemon BEFORE the user's edit: an old watermark, stamped with a definition
  // revision that no longer matches the (renamed) task. Carrying that watermark forward would make
  // the watched file look changed and start a full unattended turn for an edit that changed a name.
  h.writeRuntime({ 'T-WATCH': { definitionRevision: 'stale-revision-from-before-the-rename',
                                lastMtime: 1 } })
  h.start()

  assert.deepStrictEqual(await tickCompleted(h), [],
    'renaming a task must not fire an unattended agent run')

  const runtime = readJSON(h.ambientFile('runtime.json'))
  assert.ok(runtime['T-WATCH'].lastMtime > 1, 'the stale watermark must not survive the edit')
  assert.strictEqual(runtime['T-WATCH'].lastRun, undefined)
})

/// The complement, and the reason the rearm above cannot simply be "always baseline": when the
/// definition has NOT changed, a file that genuinely changed while the daemon was down must still
/// fire on the next start. Without this, the fix for #7 would silently become "watched files are
/// only ever noticed while the daemon happens to be running".
test('an unchanged definition still fires for a change made while the daemon was down', async (t) => {
  const h = harness(t, 'mechanician-ambient-catchup-')
  const watched = path.join(h.support, 'watched.txt')
  fs.writeFileSync(watched, 'changed while the daemon was down')

  const task = baseTask({ id: 'T-WATCH', name: 'Untouched', workspaceID: h.workspaceID,
                          trigger: { type: 'file', path: watched } })
  // An explicit revision on both sides is the "user changed nothing" case.
  task.definitionRevision = 'revision-A'
  h.writeTasks([task])
  h.writeRuntime({ 'T-WATCH': { definitionRevision: 'revision-A', lastMtime: 1 } })
  h.start()

  const runs = await waitFor(() => readJSON(h.ambientFile('runs.json')),
    'the missed file change to be picked up')
  assert.strictEqual(runs.length, 1)
  assert.strictEqual(runs[0].taskId, 'T-WATCH')
})
