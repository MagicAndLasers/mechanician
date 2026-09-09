import assert from 'node:assert/strict'
import fs from 'node:fs'
import test from 'node:test'

import { askOnDevice, listShortcuts, runShortcut } from '../src/mac-bridge/tools.mjs'

function recordingExec(stdout = '') {
  const calls = []
  return {
    calls,
    exec: async (file, args) => {
      calls.push({ file, args })
      return { stdout, stderr: '' }
    },
  }
}

test('shortcut names are parsed one per line, blanks dropped', async () => {
  const { exec } = recordingExec('Track my package\n\nCheck availability\n')

  assert.deepEqual(await listShortcuts({ exec }), ['Track my package', 'Check availability'])
})

/// The strong check is existence, not escaping: a name that is not on this Mac is refused outright,
/// so there is no quoting question to get wrong.
test('a shortcut that does not exist is refused, never passed to the runner', async () => {
  const { calls, exec } = recordingExec('Real Shortcut\n')

  await assert.rejects(
    () => runShortcut({ name: '; rm -rf ~' }, { exec, list: async () => ['Real Shortcut'] }),
    /No shortcut named/)
  assert.equal(calls.length, 0, 'nothing was executed')
})

test('an empty name is refused before anything runs', async () => {
  const { calls, exec } = recordingExec()

  await assert.rejects(() => runShortcut({ name: '   ' }, { exec, list: async () => [] }))
  assert.equal(calls.length, 0)
})

test('a real shortcut runs through argv, never a shell string', async () => {
  const { calls, exec } = recordingExec('done\n')

  const output = await runShortcut({ name: 'My Shortcut' }, { exec, list: async () => ['My Shortcut'] })

  assert.equal(output, 'done')
  assert.equal(calls[0].file, '/usr/bin/shortcuts')
  assert.deepEqual(calls[0].args, ['run', 'My Shortcut'])
})

/// Anything on argv is readable by every other process via ps, so caller-supplied text goes to a
/// 0600 file instead — and that file does not outlive the call.
test('input travels by file, not on the command line, and is cleaned up', async () => {
  const { calls, exec } = recordingExec('ok\n')

  await runShortcut(
    { name: 'My Shortcut', input: 'sensitive text' },
    { exec, list: async () => ['My Shortcut'] })

  const args = calls[0].args
  assert.equal(args.includes('--input-path'), true)
  assert.equal(args.some((a) => a.includes('sensitive text')), false, 'not on argv')
  const inputPath = args[args.indexOf('--input-path') + 1]
  assert.equal(fs.existsSync(inputPath), false, 'temporary input removed')
})

test('an empty prompt never reaches the on-device model', async () => {
  let called = false

  await assert.rejects(
    () => askOnDevice({ prompt: '' }, { ensure: async () => { called = true; return '/bin/true' } }),
    /prompt is required/)
  assert.equal(called, false)
})

/// The helper explains itself — "Apple Intelligence is off" is actionable, "command failed" is not.
test("the on-device helper's own explanation is surfaced", async () => {
  const failing = async () => {
    const error = new Error('Command failed')
    error.stderr = 'The on-device model is unavailable: unavailable(reason)'
    throw error
  }

  await assert.rejects(
    () => askOnDevice({ prompt: 'hi' }, { exec: failing, ensure: async () => '/bin/false' }),
    /on-device model is unavailable/)
})
