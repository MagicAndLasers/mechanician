#!/usr/bin/env node
// Release gate: prove the PACKAGED app retains Anthropic's signed Claude engine and can read the
// same refreshable OAuth namespace as a real GUI/Sparkle launch. This is the check that was missing
// when previous builds either could not start Claude or depended on a short-lived token snapshot.
//
//   • 0.11.0 / 0.11.2 — a minimal-PATH launch resolved the wrong `claude` (or no token), so a
//     logged-in user was reported signed out.
//   • 0.11.1 — distribution re-signing stripped the bundled engine's JIT entitlements, so the engine
//     crashed on startup ("SharedArrayBuffer is not defined").
//
// It runs the app's bundled engine under a SANITIZED, GUI-like environment (minimal PATH, no token
// overrides). The engine—not this script—reads and refreshes its app-scoped secure-storage item.
//
// Usage:  node scripts/verify-packaged-auth.mjs /path/to/Mechanician.app
//
// Exit codes:  0 = passed (or skipped because no login on this machine)   1 = FAILED, do not ship.
// A missing app-scoped login is a SKIP, not a failure, so a CI box without an account never
// false-fails; after the release machine connects once, the gate is hard there.

import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { spawnSync } from 'node:child_process'
const appPath = process.argv[2]
if (!appPath) {
  console.error('usage: verify-packaged-auth.mjs <path-to-Mechanician.app>')
  process.exit(2)
}

const engine = path.join(
  appPath, 'Contents', 'Resources', 'agentd', 'node_modules',
  '@anthropic-ai', 'claude-agent-sdk-darwin-arm64', 'claude',
)
if (!fs.existsSync(engine)) {
  console.error(`!! bundled Claude engine not found at ${engine}`)
  process.exit(1)
}

console.log(`==> verifying packaged auth: ${engine}`)
console.log('    (sanitized GUI-like env: minimal PATH, no executable or token override)')

const home = process.env.HOME
const user = process.env.USER || path.basename(home)
const supportRoot = path.join(home, 'Library', 'Application Support')
const candidates = [
  { label: 'installed', config: path.join(supportRoot, 'Mechanician', 'claude'), isolated: false },
  { label: 'development', config: path.join(supportRoot, 'Mechanician-dev', 'claude'), isolated: true },
]

let authenticated = null
for (const candidate of candidates) {
  const env = {
    HOME: home,
    USER: user,
    LOGNAME: process.env.LOGNAME || user,
    TMPDIR: process.env.TMPDIR || os.tmpdir(),
    LANG: process.env.LANG || 'en_US.UTF-8',
    PATH: '/usr/bin:/bin:/usr/sbin:/sbin',
    CLAUDE_SECURESTORAGE_CONFIG_DIR: candidate.config,
    ...(candidate.isolated ? { CLAUDE_CONFIG_DIR: candidate.config } : {}),
  }
  const probe = spawnSync(engine, ['auth', 'status', '--json'], {
    encoding: 'utf8', env, timeout: 30_000,
  })
  const out = probe.stdout || ''

  let status
  try {
    status = JSON.parse(out)
  } catch {
    console.error(`!! packaged engine failed its ${candidate.label} auth probe.`)
    console.error(`   code=${probe.status ?? probe.error?.code ?? 'n/a'} signal=${probe.signal ?? 'n/a'}`)
    const stderr = (probe.stderr || '').toString().slice(0, 800)
    if (stderr) console.error(`   stderr: ${stderr}`)
    else console.error('   engine did not return structured auth status')
    process.exit(1)
  }
  // Claude deliberately exits 1 when its structured status says loggedIn=false. That is a valid
  // account state, not an engine crash: continue to the other app-scoped profile. Any nonzero exit
  // paired with an authenticated status is internally inconsistent and must fail closed.
  if (status?.loggedIn === true && probe.status !== 0) {
    console.error(`!! packaged engine reported an authenticated ${candidate.label} account but exited ${probe.status}.`)
    process.exit(1)
  }
  const method = String(status?.authMethod || '').toLowerCase()
  if (status?.loggedIn === true && ['oauth_token', 'claude.ai', 'oauth'].includes(method)) {
    authenticated = { label: candidate.label, method: status.authMethod }
    break
  }
}

if (!authenticated) {
  console.log('SKIP: packaged engine runs, but this machine has no app-scoped Claude login to verify.')
  console.log('      After either app connects once, this gate requires refreshable secure-storage auth.')
  process.exit(0)
}

console.log(`==> OK: packaged engine authenticated from ${authenticated.label} secure storage (authMethod:${authenticated.method}).`)
