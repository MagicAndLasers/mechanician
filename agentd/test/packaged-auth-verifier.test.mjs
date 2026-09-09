import assert from 'node:assert/strict'
import { chmodSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { spawnSync } from 'node:child_process'
import test from 'node:test'
import { fileURLToPath } from 'node:url'

const here = path.dirname(fileURLToPath(import.meta.url))
const verifier = path.resolve(here, '..', '..', 'scripts', 'verify-packaged-auth.mjs')

function fakeApp(engineSource) {
  const root = mkdtempSync(path.join(os.tmpdir(), 'mechanician-packaged-auth-'))
  const app = path.join(root, 'Mechanician.app')
  const engine = path.join(app, 'Contents', 'Resources', 'agentd', 'node_modules',
    '@anthropic-ai', 'claude-agent-sdk-darwin-arm64', 'claude')
  mkdirSync(path.dirname(engine), { recursive: true })
  writeFileSync(engine, `#!/bin/sh\n${engineSource}\n`)
  chmodSync(engine, 0o755)
  return { root, app }
}

test('packaged auth verifier treats structured signed-out exit 1 as an account state', () => {
  const fixture = fakeApp(`
if [ -n "$CLAUDE_CONFIG_DIR" ]; then
  printf '%s\\n' '{"loggedIn":true,"authMethod":"claude.ai"}'
  exit 0
fi
printf '%s\\n' '{"loggedIn":false,"authMethod":"none"}'
exit 1`)
  try {
    const result = spawnSync(process.execPath, [verifier, fixture.app], {
      encoding: 'utf8', env: { ...process.env, HOME: os.homedir() },
    })
    assert.equal(result.status, 0, result.stderr)
    assert.match(result.stdout, /authenticated from development secure storage/)
  } finally {
    rmSync(fixture.root, { recursive: true, force: true })
  }
})

test('packaged auth verifier still rejects an engine that returns no structured status', () => {
  const fixture = fakeApp(`
echo 'engine crashed' >&2
exit 1`)
  try {
    const result = spawnSync(process.execPath, [verifier, fixture.app], {
      encoding: 'utf8', env: { ...process.env, HOME: os.homedir() },
    })
    assert.equal(result.status, 1)
    assert.match(result.stderr, /failed its installed auth probe/)
    assert.match(result.stderr, /engine crashed/)
  } finally {
    rmSync(fixture.root, { recursive: true, force: true })
  }
})
