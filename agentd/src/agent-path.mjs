import { execFileSync } from 'node:child_process'
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

// The PATH every shell command an agent runs will resolve against.
//
// This is the daemon-side half of the rule `AgentdRuntime.agentPath` applies to window lanes. The
// scheduler needs its own copy because nothing hands it an environment: launchd starts ambientd
// directly, with its own minimal PATH, so an unattended agent saw neither the person's tools nor
// the bundled runtime — strictly worse than a window, which at least had the bundle on PATH.
//
// Keep the two implementations behaviourally identical. Both are covered by tests that assert the
// same three properties, so a change to one that is not made to the other fails a suite.

const FALLBACK_ENTRIES = Object.freeze(['/usr/local/bin', '/usr/bin', '/bin'])

/// Compose the three sources, in this order, de-duplicated:
///
/// 1. The **login shell's** PATH — the only authority on what the person actually installed.
/// 2. Anything **inherited** the login shell did not list, so an MDM-injected entry still survives.
/// 3. The **bundled runtime**, LAST. It is a fallback for a Mac with no Node, never an override:
///    ahead of the person's own tools it replaces their `node` in every command an agent runs.
///
/// Idempotent — an entry already present is never appended twice, so a daemon restart cannot grow
/// PATH without bound.
export function agentPath({ login, inherited, runtime } = {}) {
  const seen = new Set()
  const entries = []
  for (const source of [login, inherited]) {
    if (typeof source !== 'string') continue
    for (const entry of source.split(':')) {
      if (!entry || seen.has(entry)) continue
      seen.add(entry)
      entries.push(entry)
    }
  }
  if (entries.length === 0) {
    for (const entry of FALLBACK_ENTRIES) { seen.add(entry); entries.push(entry) }
  }
  if (typeof runtime === 'string' && runtime && !seen.has(runtime)) entries.push(runtime)
  return entries.join(':')
}

/// Ask the person's login shell for its PATH.
///
/// `printenv` rather than `echo $PATH`: fish and friends do not share POSIX variable syntax, but
/// every shell can exec a binary. A shell that hangs — waiting on a prompt in a login file, or a
/// slow network mount — must not wedge the daemon, so the read is bounded and failure is silent:
/// the inherited PATH is still a working, if smaller, environment.
export function loginShellPath({
  shell = process.env.SHELL,
  timeoutMs = 2000,
  exec = execFileSync,
} = {}) {
  const shellPath = typeof shell === 'string' && shell ? shell : '/bin/zsh'
  try {
    fs.accessSync(shellPath, fs.constants.X_OK)
    const output = exec(shellPath, ['-lc', '/usr/bin/printenv PATH'], {
      encoding: 'utf8', timeout: timeoutMs, stdio: ['ignore', 'pipe', 'ignore'],
    })
    const value = typeof output === 'string' ? output.trim() : ''
    return value || null
  } catch {
    return null
  }
}

/// Where the app stages its bundled `node`/`npm`/`npx` wrappers, relative to this module.
///
/// In a signed bundle this file is `…/Mechanician.app/Contents/Resources/agentd/src/agent-path.mjs`,
/// so the runtime directory is two levels up. In a source checkout the path does not exist, which is
/// harmless: a missing PATH entry is skipped by every shell, and a developer has their own Node.
export function bundledRuntimeDirectory(moduleURL = import.meta.url) {
  return path.resolve(path.dirname(fileURLToPath(moduleURL)), '../../runtime')
}
