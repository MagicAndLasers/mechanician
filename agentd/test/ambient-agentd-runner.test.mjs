import test from 'node:test'
import assert from 'node:assert/strict'
import { EventEmitter } from 'node:events'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'

import {
  laneRoute, isLaneRunnable, createLineReader, applyAgentdEvent, newRunState,
  mcpBlockedReasonFromExtensions, readMcpBlockedReason, runTurnViaAgentd,
} from '../src/ambient-agentd-runner.mjs'
import {
  unattendedToolAuthorization, unattendedToolSpecs, isUnattendedWithheldTool,
} from '../src/runtime-policy.mjs'

test('a lane maps to the provider/auth pair agentd expects', () => {
  assert.deepEqual(laneRoute('openai_api'), { provider: 'openai', auth: 'apikey' })
  assert.deepEqual(laneRoute('claude_vertex'), { provider: 'anthropic', auth: 'vertex' })
  assert.equal(laneRoute('claude_subscription'), null)
  for (const inheritedName of ['__proto__', 'constructor', 'toString']) {
    assert.equal(laneRoute(inheritedName), null)
    assert.equal(isLaneRunnable(inheritedName), false)
  }
  assert.equal(isLaneRunnable('codex_subscription'), false,
    'subscription lanes have no unattended runtime and must not be schedulable')
})

test('NDJSON arrives in arbitrary chunks and still parses', () => {
  const seen = []
  const read = createLineReader((v) => seen.push(v))
  read('{"type":"rea')
  read('dy"}\n{"type":"delta","text":"he')
  read('llo"}\n')
  assert.deepEqual(seen, [{ type: 'ready' }, { type: 'delta', text: 'hello' }])
})

test('one malformed line does not lose the rest of the turn', () => {
  const seen = []
  const read = createLineReader((v) => seen.push(v))
  read('not json\n{"type":"done"}\n')
  assert.deepEqual(seen, [{ type: 'done' }])
})

test('assistant text accumulates across deltas', () => {
  const s = newRunState()
  applyAgentdEvent(s, { type: 'delta', text: 'a' })
  applyAgentdEvent(s, { type: 'delta', text: 'b' })
  assert.equal(s.text, 'ab')
  assert.equal(s.finished, false)
})

test('an artifact event is captured for the standalone store', () => {
  const s = newRunState()
  applyAgentdEvent(s, {
    type: 'artifact', id: 'turn-1', artifactType: 'html', title: 'T', source: '<p>done</p>',
  })
  assert.deepEqual(s.artifacts, [{ title: 'T', type: 'html', source: '<p>done</p>' }])
})

test('an unreadable artifact handoff is always removed and only an inline fallback survives', () => {
  const removed = []
  const failingFiles = {
    readFile: () => { throw new Error('unreadable fixture') },
    removeFile: (sourcePath) => removed.push(sourcePath),
  }

  const missing = newRunState()
  applyAgentdEvent(missing, {
    type: 'artifact', artifactType: 'html', title: 'Missing', sourcePath: '/tmp/missing.src',
  }, failingFiles)
  assert.deepEqual(missing.artifacts, [])

  const fallback = newRunState()
  applyAgentdEvent(fallback, {
    type: 'artifact', artifactType: 'markdown', title: 'Fallback', source: '# Inline',
    sourcePath: '/tmp/unreadable.src',
  }, failingFiles)
  assert.deepEqual(fallback.artifacts, [{ title: 'Fallback', type: 'markdown', source: '# Inline' }])
  assert.deepEqual(removed, ['/tmp/missing.src', '/tmp/unreadable.src'])
})

test('a permission prompt is answered rather than left to hang', () => {
  // Unattended agentd decides from policy, but if any adapter still prompts, a scheduled run must
  // not stall until its timeout.
  const s = newRunState()
  applyAgentdEvent(s, {
    type: 'permission_request', id: 'turn-1', permissionId: 'p1', name: 'Bash',
  },
    { permissionMode: 'dontAsk' })
  assert.deepEqual(s.reply, {
    type: 'permission_response', id: 'turn-1', permissionId: 'p1', responseId: 'p1',
    allow: false, always: false, message: 'Scheduled tasks cannot ask for permission.',
  })
  assert.deepEqual(s.permissionDenials, ['Bash'])
})

test('a trusted task allows what it was explicitly trusted for', () => {
  const s = newRunState()
  applyAgentdEvent(s, {
    type: 'permission_request', id: 'turn-2', permissionId: 'p2', name: 'Bash',
  },
    { permissionMode: 'bypassPermissions' })
  assert.deepEqual(s.reply, {
    type: 'permission_response', id: 'turn-2', permissionId: 'p2', responseId: 'p2',
    allow: true, always: false,
  })
  assert.deepEqual(s.permissionDenials, [])
})

test('a question gets an empty protocol response, because nobody can answer it', () => {
  const s = newRunState()
  applyAgentdEvent(s, { type: 'question_request', id: 'turn-3', reqId: 'ask-1' })
  assert.deepEqual(s.reply, {
    type: 'question_response', id: 'turn-3', reqId: 'ask-1', responseId: 'ask-1',
    answers: {},
  })
})

test('error and done are terminal', () => {
  const errored = newRunState()
  applyAgentdEvent(errored, { type: 'error', message: 'boom' })
  assert.equal(errored.error, 'boom')
  assert.equal(errored.finished, true)

  const ok = newRunState()
  applyAgentdEvent(ok, { type: 'done' })
  assert.equal(ok.finished, true)
  assert.equal(ok.error, null)
})

// ── Unattended tool policy ──────────────────────────────────────────────────────

test('tools that need a person are withheld, not merely denied', () => {
  for (const name of [
    'Question', 'WaitFor', 'RunShortcut', 'ComputerScreenshot', 'RunAppleScript',
    'SearchMechanicianHelp', 'mcp__help__SearchMechanicianHelp',
    'ShowMechanician', 'mcp__help__ShowMechanician',
  ]) {
    assert.equal(isUnattendedWithheldTool(name), true, name)
    assert.equal(unattendedToolAuthorization({ name, permissionMode: 'bypassPermissions' }), 'deny',
      `${name} must stay denied even for a trusted task — there is still nobody there`)
  }
})

test('a default scheduled task gets the read-only surface only', () => {
  const specs = [{ name: 'Read' }, { name: 'SearchFiles' }, { name: 'Write' }, { name: 'Bash' },
                 { name: 'CreateOrUpdateArtifact' }, { name: 'Question' },
                 { name: 'ShowMechanician' }]
  const offered = unattendedToolSpecs(specs, { permissionMode: 'dontAsk' }).map((s) => s.name)
  assert.deepEqual(offered, ['Read', 'SearchFiles', 'CreateOrUpdateArtifact'])
})

test('a Trust-all task gets the write surface but never the interactive one', () => {
  const specs = [{ name: 'Read' }, { name: 'Write' }, { name: 'Bash' }, { name: 'Question' },
                 { name: 'ComputerAction' }, { name: 'ShowMechanician' }]
  const offered = unattendedToolSpecs(specs, { permissionMode: 'bypassPermissions' }).map((s) => s.name)
  assert.deepEqual(offered, ['Read', 'Write', 'Bash'])
})

test('unattended authorization never returns prompt', () => {
  for (const name of ['Read', 'Write', 'Bash', 'Question', 'CreateOrUpdateArtifact']) {
    for (const permissionMode of ['dontAsk', 'bypassPermissions', 'default']) {
      const decision = unattendedToolAuthorization({ name, permissionMode })
      assert.ok(decision === 'allow' || decision === 'deny',
        `${name}/${permissionMode} produced ${decision}; a prompt would hang the run`)
    }
  }
})

// ── End to end against a fake agentd ────────────────────────────────────────────

function fakeAgentd(script) {
  return () => {
    const child = new EventEmitter()
    child.stdout = new EventEmitter()
    child.stderr = new EventEmitter()
    child.stdout.setEncoding = () => {}
    child.stderr.setEncoding = () => {}
    child.kill = () => {}
    child.stdin = {
      write: (line) => {
        const sent = JSON.parse(line)
        queueMicrotask(() => script(child, sent))
        return true
      },
    }
    queueMicrotask(() => child.stdout.emit('data', '{"type":"ready"}\n'))
    return child
  }
}

test('a full turn forwards its resolved workspace instructions after ready', async () => {
  let sentTurn = null
  const result = await runTurnViaAgentd({
    access: 'openai_api', prompt: 'summarize', cwd: '/tmp', permissionMode: 'dontAsk',
    projectInstructions: 'Keep the report concise.',
    spawnFn: fakeAgentd((child, sent) => {
      sentTurn = sent
      child.stdout.emit('data', '{"type":"delta","text":"done "}\n')
      child.stdout.emit('data', '{"type":"delta","text":"deal"}\n')
      child.stdout.emit('data', '{"type":"done"}\n')
    }),
  })
  assert.equal(result.text, 'done deal')
  assert.equal(result.error, null)
  assert.equal(sentTurn.type, 'send')
  assert.equal(sentTurn.prompt, 'summarize')
  assert.equal(sentTurn.cwd, '/tmp')
  assert.equal(sentTurn.projectInstructions, 'Keep the report concise.')
})

test('a scheduled run discards an unretained generated-image handoff', async (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'mechanician-ambient-image-'))
  const handoff = path.join(root, 'mechanician-generated-image-fixture.image')
  fs.writeFileSync(handoff, 'fixture image bytes')
  t.after(() => fs.rmSync(root, { recursive: true, force: true }))

  await runTurnViaAgentd({
    access: 'openai_api', prompt: 'x', cwd: '/tmp',
    spawnFn: fakeAgentd((child) => {
      child.stdout.emit('data', `${JSON.stringify({
        type: 'tool_result', generatedImagePath: handoff,
      })}\n`)
      child.stdout.emit('data', '{"type":"done"}\n')
    }),
  })

  assert.equal(fs.existsSync(handoff), false)
})

test('a scheduled run collects a large file-backed artifact and removes its handoff', async (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'mechanician-ambient-artifact-'))
  const handoff = path.join(root, 'mechanician-artifact-fixture.src')
  const source = `<main>${'large artifact '.repeat(600)}</main>`
  fs.writeFileSync(handoff, source)
  t.after(() => fs.rmSync(root, { recursive: true, force: true }))

  const result = await runTurnViaAgentd({
    access: 'openai_api', prompt: 'x', cwd: '/tmp',
    spawnFn: fakeAgentd((child) => {
      child.stdout.emit('data', `${JSON.stringify({
        type: 'artifact', id: 'turn-1', artifactType: 'html', title: 'Large report',
        sourcePath: handoff,
      })}\n`)
      child.stdout.emit('data', '{"type":"done"}\n')
    }),
  })

  assert.deepEqual(result.artifacts, [{ title: 'Large report', type: 'html', source }])
  assert.equal(fs.existsSync(handoff), false)
})

test('the turn is not sent before the lane reports ready', async () => {
  // Sending early races agentd's credential and runtime bring-up.
  const order = []
  await runTurnViaAgentd({
    access: 'openai_api', prompt: 'x', cwd: '/tmp',
    spawnFn: () => {
      const child = new EventEmitter()
      child.stdout = new EventEmitter(); child.stderr = new EventEmitter()
      child.stdout.setEncoding = () => {}; child.stderr.setEncoding = () => {}
      child.kill = () => {}
      child.stdin = { write: () => { order.push('send'); queueMicrotask(() => child.stdout.emit('data', '{"type":"done"}\n')) } }
      queueMicrotask(() => { order.push('ready'); child.stdout.emit('data', '{"type":"ready"}\n') })
      return child
    },
  })
  assert.deepEqual(order, ['ready', 'send'])
})

test('a runtime that dies before finishing reports why', async () => {
  const result = await runTurnViaAgentd({
    access: 'openai_api', prompt: 'x', cwd: '/tmp',
    spawnFn: fakeAgentd((child) => { child.emit('exit', 1) }),
  })
  assert.match(result.error, /exited \(code 1\)/)
})

test('a lane with no unattended runtime is refused before spawning', async () => {
  await assert.rejects(
    () => runTurnViaAgentd({ access: 'claude_subscription', prompt: 'x', cwd: '/tmp' }),
    /No unattended runtime/)
})

test('a pending MCP credential boundary refuses unattended work before provider exposure', async () => {
  let spawned = false
  await assert.rejects(
    () => runTurnViaAgentd({
      access: 'anthropic_api', prompt: 'Use the server.', cwd: '/tmp',
      mcpBlockedReason: 'VICE authorization is waiting for an exact tool inventory.',
      spawnFn: (...args) => {
        spawned = true
        return fakeAgentd((child) => child.stdout.emit('data', '{"type":"done"}\n'))(...args)
      },
    }),
    /VICE authorization.*exact tool inventory/i)
  assert.equal(spawned, false,
    'scheduled work must fail before a daemon can receive the unattended prompt')
})

test('the persisted MCP gate is exact-access scoped and never exposes ledger identities', () => {
  const payload = {
    pendingMCPReadiness: {
      byAccess: {
        anthropic_api: [{
          name: 'Private Server Name', changeId: 'private-generation', source: 'configured',
          serverId: '7F661A72-4885-42AD-BCE1-242B6741D88A',
        }],
      },
    },
    pendingMCPAuthorizations: {
      byAccess: {
        claude_vertex: [{ id: 'private-attempt', name: 'Other Private Server' }],
      },
    },
  }

  const anthropicReason = mcpBlockedReasonFromExtensions(payload, 'anthropic_api')
  const vertexReason = mcpBlockedReasonFromExtensions(payload, 'claude_vertex')
  assert.match(anthropicReason, /fresh tool check/i)
  assert.match(vertexReason, /fresh tool check/i)
  assert.equal(mcpBlockedReasonFromExtensions(payload, 'openai_api'), null,
    'another provider lane cannot block this task')
  for (const reason of [anthropicReason, vertexReason]) {
    assert.doesNotMatch(reason, /Private Server|private-generation|private-attempt/,
      'run reports carry only a non-secret Boolean-style explanation')
  }
})

test('missing old ledgers are empty while malformed or unreadable state fails closed', () => {
  assert.equal(mcpBlockedReasonFromExtensions({}, 'anthropic_api'), null)
  assert.equal(mcpBlockedReasonFromExtensions({
    pendingMCPReadiness: { byAccess: { anthropic_api: [] } },
    pendingMCPAuthorizations: { byAccess: {} },
  }, 'anthropic_api'), null)
  assert.match(mcpBlockedReasonFromExtensions({
    pendingMCPReadiness: { byAccess: { anthropic_api: 'not-an-array' } },
  }, 'anthropic_api'), /could not verify/i)
  assert.match(readMcpBlockedReason('/unused', 'anthropic_api', {
    readFile: () => '{not json',
  }), /could not verify/i)
  assert.equal(readMcpBlockedReason('/missing', 'anthropic_api', {
    readFile: () => { const error = new Error('missing'); error.code = 'ENOENT'; throw error },
  }), null)
})

test('the scheduler forwards no provider secrets to the child', async () => {
  let childEnv = null
  await runTurnViaAgentd({
    access: 'openai_api', prompt: 'x', cwd: '/tmp',
    env: { HOME: '/Users/x' },
    spawnFn: (_cmd, _args, opts) => {
      childEnv = opts.env
      const child = new EventEmitter()
      child.stdout = new EventEmitter(); child.stderr = new EventEmitter()
      child.stdout.setEncoding = () => {}; child.stderr.setEncoding = () => {}
      child.kill = () => {}
      child.stdin = { write: () => queueMicrotask(() => child.stdout.emit('data', '{"type":"done"}\n')) }
      queueMicrotask(() => child.stdout.emit('data', '{"type":"ready"}\n'))
      return child
    },
  })
  assert.equal(childEnv.MECHANICIAN_PROVIDER, 'openai')
  assert.equal(childEnv.MECHANICIAN_UNATTENDED, '1')
  assert.ok(!('OPENAI_API_KEY' in childEnv),
    'agentd resolves its own credential from the Keychain; the scheduler must not handle secrets')
})
