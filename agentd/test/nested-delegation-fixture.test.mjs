import test from 'node:test'
import assert from 'node:assert/strict'
import { spawn } from 'node:child_process'
import { fileURLToPath } from 'node:url'
import path from 'node:path'

const fixture = path.join(
  path.dirname(fileURLToPath(import.meta.url)), 'fixtures', 'nested-delegation-fixture.mjs')

// The corpus seed must actually emit the topology it exists to pin: a three-deep delegation
// chain plus a sender-owned cross-child message. If this shape regresses, the format review's semantic-root
// comparison silently loses its hardest case.
test('nested delegation seed emits the full parent chain and the cross-child message', async () => {
  const child = spawn(process.execPath, [fixture], { stdio: ['pipe', 'pipe', 'inherit'] })
  const events = []
  let buffered = ''
  const done = new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error('fixture never emitted done')), 15000)
    child.stdout.on('data', (chunk) => {
      buffered += chunk
      let index
      while ((index = buffered.indexOf('\n')) >= 0) {
        const line = buffered.slice(0, index)
        buffered = buffered.slice(index + 1)
        if (!line.trim()) continue
        const event = JSON.parse(line)
        events.push(event)
        if (event.type === 'done') { clearTimeout(timer); resolve() }
      }
    })
    child.on('error', reject)
  })
  child.stdin.write(`${JSON.stringify({ type: 'send', id: 'turn-1', prompt: 'go' })}\n`)
  await done
  child.kill()

  const tasks = events.filter((e) => e.type === 'tool_use' && e.name === 'Task')
  const parentOf = Object.fromEntries(tasks.map((e) => [e.toolUseId, e.parentToolUseId ?? null]))
  assert.equal(parentOf['child-a'], null)
  assert.equal(parentOf['child-b'], null)
  assert.equal(parentOf['grandchild-a1'], 'child-a')
  assert.equal(parentOf['greatgrandchild-a1x'], 'grandchild-a1')

  const message = events.find((e) => e.type === 'tool_use' && e.name === 'SendMessage')
  assert.ok(message, 'the cross-child message must be present')
  assert.equal(message.parentToolUseId, 'child-a', 'the wire can only attribute the SENDER')
  assert.equal(
    message.input.recipient, 'child-b',
    'the recipient exists only inside input — the documented not-captured linkage')

  // Every spawned delegate resolves; the deepest resolves first (unwind order).
  const results = events
    .filter((e) => e.type === 'tool_result')
    .map((e) => e.toolUseId)
  for (const id of ['greatgrandchild-a1x', 'grandchild-a1', 'child-a', 'child-b']) {
    assert.ok(results.includes(id), `missing tool_result for ${id}`)
  }
  assert.ok(
    results.indexOf('greatgrandchild-a1x') < results.indexOf('grandchild-a1')
      && results.indexOf('grandchild-a1') < results.indexOf('child-a'),
    'the chain unwinds deepest-first')
})
