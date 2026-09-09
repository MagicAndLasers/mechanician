// Regression guard for Claude auth after a GUI/Sparkle relaunch.
//
// A GUI app has a minimal PATH. Subscription state must come from the package-lock-pinned Claude
// engine using Mechanician's app-scoped secure-storage namespace—not a PATH wrapper and not a copied
// access-token snapshot. The engine remains responsible for refresh.

import assert from 'node:assert/strict'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { spawn } from 'node:child_process'
import { fileURLToPath } from 'node:url'
import { test } from 'node:test'

const here = path.dirname(fileURLToPath(import.meta.url))
const agentd = path.resolve(here, '../src/agentd.mjs')

function fakeSystem(t, { loggedIn }) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'mechanician-auth-launch-'))
  const bin = path.join(root, 'bin')
  const home = path.join(root, 'home')
  const engine = path.join(root, 'claude-engine')
  const statusEnvironment = path.join(root, 'status.environment')
  fs.mkdirSync(bin, { recursive: true })
  fs.mkdirSync(home, { recursive: true })

  fs.writeFileSync(engine, `#!/bin/sh
if [ "$1" = "auth" ] && [ "$2" = "status" ]; then
  printf '%s\n%s\n' "$CLAUDE_CONFIG_DIR" "$CLAUDE_SECURESTORAGE_CONFIG_DIR" > "$MECHANICIAN_TEST_STATUS_ENVIRONMENT"
  echo '${loggedIn
    ? '{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty"}'
    : '{"loggedIn":false,"authMethod":"none","apiProvider":"firstParty"}'}'
  exit 0
fi
exit 1
`)
  fs.chmodSync(engine, 0o755)

  // A hostile PATH command proves auth never discovers or executes it.
  fs.writeFileSync(path.join(bin, 'claude'), '#!/bin/sh\necho PATH wrapper executed >&2\nexit 127\n')
  fs.chmodSync(path.join(bin, 'claude'), 0o755)
  t.after(() => fs.rmSync(root, { recursive: true, force: true }))
  return { bin, home, engine, statusEnvironment }
}

function startPrimaryLane(t, system) {
  const child = spawn(process.execPath, [agentd], {
    env: {
      HOME: system.home,
      PATH: system.bin,
      MECHANICIAN_PROVIDER: 'anthropic',
      MECHANICIAN_AUTH: 'subscription',
      MECHANICIAN_ACCOUNT_DISABLED: '0',
      MECHANICIAN_CLAUDE_AUTH_BIN: system.engine,
      MECHANICIAN_TEST_STATUS_ENVIRONMENT: system.statusEnvironment,
      CLAUDE_CODE_OAUTH_TOKEN: '',
      ANTHROPIC_API_KEY: '',
      OPENAI_API_KEY: '',
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
    for (const line of lines) if (line) { try { events.push(JSON.parse(line)) } catch {} }
  })
  t.after(() => child.kill())
  return events
}

async function waitForReady(events, timeoutMs = 15_000) {
  const deadline = Date.now() + timeoutMs
  while (Date.now() < deadline) {
    const ready = events.find((event) => event.type === 'ready')
    if (ready) return ready
    await new Promise((resolve) => setTimeout(resolve, 50))
  }
  throw new Error('timed out waiting for ready event')
}

test('primary subscription status is launch-independent and uses app-scoped secure storage', async (t) => {
  const system = fakeSystem(t, { loggedIn: true })
  const events = startPrimaryLane(t, system)
  const ready = await waitForReady(events)
  assert.equal(ready.loggedIn, true)

  const [configDir, secureStorageDir] = fs.readFileSync(system.statusEnvironment, 'utf8').split('\n')
  assert.equal(configDir, '', 'the primary lane retains default Claude session storage')
  assert.equal(
    secureStorageDir,
    path.join(system.home, 'Library', 'Application Support', 'Mechanician', 'claude'),
  )
})

test('a genuinely signed-out app-scoped Claude account stays signed out', async (t) => {
  const system = fakeSystem(t, { loggedIn: false })
  const events = startPrimaryLane(t, system)
  const ready = await waitForReady(events)
  assert.equal(ready.loggedIn, false)
})
