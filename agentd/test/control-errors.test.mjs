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
  const config = fs.mkdtempSync(path.join(os.tmpdir(), 'mechanician-control-errors-'))
  const child = spawn(process.execPath, [agentd], {
    env: {
      ...process.env,
      MECHANICIAN_PROVIDER: 'anthropic',
      MECHANICIAN_AUTH: 'apikey',
      MECHANICIAN_CONFIG_DIR: config,
      OPENAI_API_KEY: '',
      ANTHROPIC_API_KEY: '',
      MECHANICIAN_ENABLE_MOCK_PROVIDER: '1',
      // Prevent agentd's normal macOS Keychain fallback from finding a developer API key.
      // Node itself is already an absolute executable, and explicit test mock mode needs no shell tools.
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

test('control failures are non-terminal while a turn keeps streaming', async (t) => {
  const { child, events } = startAgentd(t)
  await waitFor(() => events.find((event) => event.type === 'ready'), 'ready')

  child.stdin.write(`${JSON.stringify({ type: 'send', id: 'turn-1', prompt: 'keep working' })}\n`)
  await waitFor(() => events.find((event) => event.type === 'delta' && event.id === 'turn-1'),
                'first turn delta')
  const deltasBeforeControl = events.filter((event) => event.type === 'delta').length
  child.stdin.write(`${JSON.stringify({ type: 'set_cwd', id: 'cwd-1', path: '/definitely/missing' })}\n`)
  child.stdin.write(`${JSON.stringify({ type: 'unknown_fixture_request', id: 'unknown-1' })}\n`)
  child.stdin.write('{bad json\n')

  await waitFor(() => events.find((event) => event.type === 'done' && event.id === 'turn-1'),
                'turn completion')

  assert.deepEqual(
    events.filter((event) => event.type === 'control_error').map((event) => event.id).sort(),
    [null, 'cwd-1', 'unknown-1'].sort(),
  )
  assert.equal(events.some((event) => event.type === 'error' && event.id !== 'turn-1'), false)
  assert.ok(events.filter((event) => event.type === 'delta' && event.id === 'turn-1').length
            > deltasBeforeControl)
})

test('stale permission responses are rejected explicitly instead of appearing allowed', async (t) => {
  const { child, events } = startAgentd(t)
  await waitFor(() => events.find((event) => event.type === 'ready'), 'ready')

  child.stdin.write(`${JSON.stringify({
    type: 'permission_response', id: 'finished-turn', permissionId: 'raw-permission',
    responseId: 'anthropic_api:finished-turn:raw-permission', allow: true, always: false,
  })}\n`)
  const acknowledgement = await waitFor(
    () => events.find((event) => event.type === 'permission_response_ack'),
    'stale permission acknowledgement',
  )

  assert.deepEqual(acknowledgement, {
    type: 'permission_response_ack', id: 'finished-turn',
    permissionId: 'anthropic_api:finished-turn:raw-permission',
    accepted: false, allow: true,
    message: 'This approval request is no longer active.',
  })
})
