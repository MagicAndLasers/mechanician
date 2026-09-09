// Resolve the pinned Codex App Server shipped with Mechanician.
//
// The release bundle installs @openai/codex from package-lock.json beside agentd.
// Invoke the platform Mach-O directly: the npm launcher uses `#!/usr/bin/env node`, which is
// unsuitable for a GUI-launched app whose PATH intentionally does not expose the bundled Node.

import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { execFileSync } from 'node:child_process'

export const BUNDLED_CODEX_VERSION = '0.148.0'
export const BUNDLED_CODEX_SCHEMA_LOCK = Object.freeze(JSON.parse(
  fs.readFileSync(new URL('./codex-app-server-schema.lock.json', import.meta.url), 'utf8'),
))
export const BUNDLED_CODEX_RELATIVE_PATH = path.join(
  '..',
  'node_modules',
  '@openai',
  'codex-darwin-arm64',
  'vendor',
  'aarch64-apple-darwin',
  'bin',
  'codex',
)

export function bundledCodexPath(agentdDirectory) {
  return path.resolve(agentdDirectory, BUNDLED_CODEX_RELATIVE_PATH)
}

export function codexBinaryCandidates({
  environment = process.env,
  agentdDirectory,
  homeDirectory = os.homedir(),
  platform = process.platform,
  architecture = process.arch,
} = {}) {
  const candidates = []
  if (environment.MECHANICIAN_CODEX_BIN) candidates.push(environment.MECHANICIAN_CODEX_BIN)
  if (agentdDirectory && platform === 'darwin' && architecture === 'arm64') {
    candidates.push(bundledCodexPath(agentdDirectory))
  }
  candidates.push(
    '/Applications/ChatGPT.app/Contents/Resources/codex',
    '/opt/homebrew/bin/codex',
    '/usr/local/bin/codex',
    path.join(homeDirectory, '.local', 'bin', 'codex'),
  )
  return [...new Set(candidates.filter(Boolean))]
}

export function resolveCodexBinary({
  isExecutable = (candidate) => {
    try { fs.accessSync(candidate, fs.constants.X_OK); return true }
    catch { return false }
  },
  which = () => {
    try { return execFileSync('/usr/bin/which', ['codex'], { encoding: 'utf8' }).trim() || null }
    catch { return null }
  },
  ...candidateOptions
} = {}) {
  for (const candidate of codexBinaryCandidates(candidateOptions)) {
    if (isExecutable(candidate)) return candidate
  }
  const found = which()
  return found && isExecutable(found) ? found : null
}
