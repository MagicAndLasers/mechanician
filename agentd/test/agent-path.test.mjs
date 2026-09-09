import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import test from 'node:test'

import { agentPath, bundledRuntimeDirectory, loginShellPath } from '../src/agent-path.mjs'

const SRC = resolve(dirname(fileURLToPath(import.meta.url)), '../src')

test('the person\'s own tools resolve before anything the app supplies', () => {
  const path = agentPath({
    login: '/opt/homebrew/bin:/usr/bin:/bin',
    inherited: '/usr/bin:/bin:/usr/sbin:/sbin',
    runtime: '/Applications/Mechanician.app/Contents/Resources/runtime',
  })

  assert.ok(path.startsWith('/opt/homebrew/bin:/usr/bin:/bin'), path)
  // The bundled runtime is a fallback, never an override: its node must not shadow theirs.
  assert.ok(path.endsWith(':/Applications/Mechanician.app/Contents/Resources/runtime'), path)
  // An inherited entry the login shell did not list still survives.
  assert.ok(path.split(':').includes('/usr/sbin'), path)
})

test('a daemon restart cannot grow PATH without bound', () => {
  const once = agentPath({ login: '/usr/bin:/bin', inherited: null, runtime: '/bundle/runtime' })
  const twice = agentPath({ login: once, inherited: once, runtime: '/bundle/runtime' })

  assert.equal(twice, once)
  const entries = twice.split(':')
  assert.equal(entries.length, new Set(entries).size)
})

test('an unreadable login shell leaves a working environment', () => {
  assert.equal(
    agentPath({ login: null, inherited: '/usr/bin:/bin', runtime: '/bundle/runtime' }),
    '/usr/bin:/bin:/bundle/runtime')
  assert.equal(agentPath({}), '/usr/local/bin:/usr/bin:/bin')
})

test('the login shell is asked with printenv, not shell-specific syntax', () => {
  const calls = []
  const value = loginShellPath({
    shell: '/bin/sh',
    exec: (file, args) => { calls.push({ file, args }); return '  /opt/homebrew/bin:/usr/bin \n' },
  })

  assert.equal(value, '/opt/homebrew/bin:/usr/bin')
  assert.deepEqual(calls, [{ file: '/bin/sh', args: ['-lc', '/usr/bin/printenv PATH'] }])
})

test('a hanging or failing login shell is silent, never fatal', () => {
  assert.equal(loginShellPath({ shell: '/bin/sh', exec: () => { throw new Error('ETIMEDOUT') } }), null)
  assert.equal(loginShellPath({ shell: '/bin/sh', exec: () => '   ' }), null)
  assert.equal(loginShellPath({ shell: '/nonexistent/shell', exec: () => '/usr/bin' }), null)
})

test('the bundled runtime resolves beside the payload in a signed bundle', () => {
  const inBundle = bundledRuntimeDirectory(
    'file:///Applications/Mechanician.app/Contents/Resources/agentd/src/agent-path.mjs')

  assert.equal(inBundle, '/Applications/Mechanician.app/Contents/Resources/runtime')
})

test('the scheduler resolves its PATH before either lane spawns', () => {
  // Both ambient lanes inherit `process.env`: the Claude `query()` stream and `runTurnViaAgentd`.
  // Pin the single assignment that covers them, because a daemon that skips it is indistinguishable
  // from a working one until a scheduled task reports a missing command.
  const ambientd = readFileSync(join(SRC, 'ambientd.mjs'), 'utf8')
  assert.match(ambientd, /process\.env\.PATH = agentPath\(\{/)
  assert.match(ambientd, /login: loginShellPath\(\)/)
  assert.match(ambientd, /runtime: bundledRuntimeDirectory\(\)/)
  // Ahead of the first spawn: the lane routes are chosen further down the file.
  assert.ok(
    ambientd.indexOf('process.env.PATH = agentPath({') < ambientd.indexOf('const stream = query({'),
    'PATH is resolved after a lane already spawned')
})
