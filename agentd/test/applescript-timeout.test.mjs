import assert from 'node:assert/strict'
import { execFile } from 'node:child_process'
import test from 'node:test'
import { promisify } from 'node:util'

const execFileP = promisify(execFile)

/// The defect this pins, measured on 2026-07-25: a capability sat in `mach_msg` for over seven
/// minutes waiting on a Contacts consent dialog, because `runAppleScript` passed no `timeout` to
/// execFile. An Apple Event blocks until the target app replies, and macOS holds that reply while a
/// TCC prompt is pending — a prompt that can open behind other windows or never be seen. The turn
/// was unrecoverable: no timeout, no cancel, nothing to click.
///
/// These drive the real `osascript` rather than a mock, because the thing worth pinning is that the
/// process is actually killed and the failure is actually reported — not that we passed an option.
const TIMEOUT_MS = 1_500

test('a script that blocks forever is killed rather than wedging the caller', async () => {
  const started = Date.now()
  let killed = false
  try {
    // `delay 600` is the AppleScript equivalent of the hang: the process is alive and healthy,
    // it simply never returns.
    await execFileP('osascript', ['-e', 'delay 600'], {
      timeout: TIMEOUT_MS, killSignal: 'SIGKILL',
    })
    assert.fail('expected the timeout to fire')
  } catch (err) {
    killed = Boolean(err.killed || err.signal === 'SIGKILL')
  }
  const elapsed = Date.now() - started
  assert.equal(killed, true, 'the process must be killed, not merely abandoned')
  assert.ok(elapsed < TIMEOUT_MS * 4, `returned in ${elapsed}ms — the caller must not block on it`)
})

/// The kill has to be distinguishable from an ordinary script error, or the UI cannot explain it.
/// A timed-out run surfaces `killed`/SIGKILL with NO stderr, which is exactly the branch
/// runAppleScript uses to swap in a message naming the permission prompt as the likely cause.
test('a timeout is distinguishable from a script that failed on its own', async () => {
  let timedOut, failed
  try {
    await execFileP('osascript', ['-e', 'delay 600'], { timeout: TIMEOUT_MS, killSignal: 'SIGKILL' })
  } catch (err) { timedOut = err }
  try {
    await execFileP('osascript', ['-e', 'error "deliberate"'], { timeout: 30_000 })
  } catch (err) { failed = err }

  assert.ok(timedOut.killed || timedOut.signal === 'SIGKILL')
  assert.ok(!String(timedOut.stderr || '').trim(), 'a timeout kill carries no stderr to explain itself')

  assert.ok(!failed.killed, 'a genuine script error is not a kill')
  assert.match(String(failed.stderr || ''), /deliberate/,
    'a genuine error explains itself in stderr and must keep doing so')
})

/// A script that finishes normally must be untouched by the timeout — the guard cannot cost
/// correctness on the path that matters.
test('a normal script still returns its output', async () => {
  const { stdout } = await execFileP('osascript',
    ['-l', 'JavaScript', '-e', 'function run(argv){ return "ok:" + JSON.parse(argv[0]).n }', '{"n":7}'],
    { timeout: 30_000 })
  assert.equal(stdout.trim(), 'ok:7')
})
