import assert from 'node:assert/strict'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { spawn } from 'node:child_process'
import { fileURLToPath } from 'node:url'
import { test } from 'node:test'

const here = path.dirname(fileURLToPath(import.meta.url))
const agentd = path.resolve(here, '../src/agentd.mjs')

function startAgentd(t) {
  const config = fs.mkdtempSync(path.join(os.tmpdir(), 'mechanician-turn-start-'))
  const child = spawn(process.execPath, [agentd], {
    env: {
      ...process.env,
      MECHANICIAN_PROVIDER: 'anthropic',
      MECHANICIAN_AUTH: 'apikey',
      MECHANICIAN_CONFIG_DIR: config,
      OPENAI_API_KEY: '',
      ANTHROPIC_API_KEY: '',
      MECHANICIAN_ENABLE_MOCK_PROVIDER: '1',
      PATH: config,
    },
    stdio: ['pipe', 'pipe', 'pipe'],
  })
  const events = []
  let buffered = ''
  child.stdout.setEncoding('utf8')
  child.stdout.on('data', (chunk) => {
    buffered += chunk
    const lines = buffered.split('\n')
    buffered = lines.pop() ?? ''
    for (const line of lines) if (line) events.push(JSON.parse(line))
  })
  t.after(() => {
    child.kill()
    fs.rmSync(config, { recursive: true, force: true })
  })
  return { child, events }
}

async function waitFor(predicate, description, timeout = 5000) {
  const deadline = Date.now() + timeout
  while (Date.now() < deadline) {
    const value = predicate()
    if (value) return value
    await new Promise((resolve) => setTimeout(resolve, 10))
  }
  assert.fail(`timed out waiting for ${description}`)
}

test('accepted send is acknowledged once before provider output', async (t) => {
  const { child, events } = startAgentd(t)
  await waitFor(() => events.find((event) => event.type === 'ready'), 'ready')

  child.stdin.write(`${JSON.stringify({ type: 'send', id: 'turn-1', prompt: 'hello' })}\n`)
  await waitFor(() => events.find((event) => event.type === 'done' && event.id === 'turn-1'),
                'turn completion')

  const acknowledgements = events.filter(
    (event) => event.type === 'turn_started' && event.id === 'turn-1')
  assert.equal(acknowledgements.length, 1)
  const ackIndex = events.findIndex(
    (event) => event.type === 'turn_started' && event.id === 'turn-1')
  const firstOutputIndex = events.findIndex(
    (event) => event.id === 'turn-1' && ['delta', 'done', 'error'].includes(event.type))
  assert.ok(ackIndex >= 0 && firstOutputIndex > ackIndex)
})

test('missing and duplicate active turn ids are rejected without a second acknowledgement', async (t) => {
  const { child, events } = startAgentd(t)
  await waitFor(() => events.find((event) => event.type === 'ready'), 'ready')

  child.stdin.write(`${JSON.stringify({ type: 'send', prompt: 'missing id' })}\n`)
  child.stdin.write(`${JSON.stringify({ type: 'send', id: 'turn-2', prompt: 'first' })}\n`)
  child.stdin.write(`${JSON.stringify({ type: 'send', id: 'turn-2', prompt: 'duplicate' })}\n`)
  await waitFor(() => events.find((event) => event.type === 'done' && event.id === 'turn-2'),
                'accepted turn completion')

  assert.equal(events.filter((event) => event.type === 'turn_started' && event.id == null).length, 0)
  assert.equal(events.filter(
    (event) => event.type === 'turn_started' && event.id === 'turn-2').length, 1)
  assert.ok(events.some(
    (event) => event.type === 'control_error'
      && event.id == null
      && /non-empty turn id/.test(event.message)))
  assert.ok(events.some(
    (event) => event.type === 'control_error'
      && event.id === 'turn-2'
      && /duplicate active turn id/.test(event.message)))
})

// Claude Opus 5 adoption, plan Phase 0 (O5-002/O5-003): the optional nested `claude` block is
// validated at the request boundary, so an ineligible preference can never become a live turn.
test('an all-default claude block runs a normal turn, and an ungated one is refused', async (t) => {
  const { child, events } = startAgentd(t)
  await waitFor(() => events.find((event) => event.type === 'ready'), 'ready')

  // A conversation that persisted its defaults must behave exactly like one that sends nothing.
  child.stdin.write(`${JSON.stringify({
    type: 'send', id: 'turn-claude-default', prompt: 'hello',
    claude: { advisor: { mode: 'off' }, speed: 'standard', refusalFallback: { mode: 'off' } },
  })}\n`)
  await waitFor(() => events.find((event) => event.type === 'done' && event.id === 'turn-claude-default'),
                'default-preference turn completion')
  assert.equal(events.filter(
    (event) => event.type === 'turn_started' && event.id === 'turn-claude-default').length, 1)

  // Fast mode is not enabled in this build: refuse the request rather than silently ignoring a
  // preference the user believes is active, and never acknowledge a turn for it.
  child.stdin.write(`${JSON.stringify({
    type: 'send', id: 'turn-claude-fast', prompt: 'hello', claude: { speed: 'fast' },
  })}\n`)
  await waitFor(() => events.find(
    (event) => event.type === 'control_error' && event.id === 'turn-claude-fast'),
                'refusal of an ungated preference')

  assert.match(
    events.find((event) => event.type === 'control_error' && event.id === 'turn-claude-fast').message,
    /Fast mode is not available in this build/)
  assert.equal(events.filter(
    (event) => event.type === 'turn_started' && event.id === 'turn-claude-fast').length, 0)
  // A rejected request must not consume the turn id or leave a phantom accepted turn.
  assert.equal(events.filter((event) => event.id === 'turn-claude-fast' && event.type === 'done').length, 0)
})

test('an acknowledged turn drains normally when the control input closes', async (t) => {
  const { child, events } = startAgentd(t)
  await waitFor(() => events.find((event) => event.type === 'ready'), 'ready')

  child.stdin.end(`${JSON.stringify({ type: 'send', id: 'turn-3', prompt: 'finish' })}\n`)
  await waitFor(() => events.find((event) => event.type === 'turn_started' && event.id === 'turn-3'),
                'turn acknowledgement')
  await waitFor(() => events.find((event) => event.type === 'done' && event.id === 'turn-3'),
                'turn completion after input close')
  await waitFor(() => child.exitCode != null, 'clean daemon exit')

  assert.equal(child.exitCode, 0)
  assert.equal(events.filter(
    (event) => event.type === 'turn_started' && event.id === 'turn-3').length, 1)
})
