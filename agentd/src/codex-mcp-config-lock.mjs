// Cross-process writer lock for the Codex MCP managed config region.
//
// Every Mechanician window owns a daemon while all Codex lanes share CODEX_HOME, so the managed
// region of config.toml has writers in unrelated processes. The acquisition primitive and why a
// pathname lock is the wrong tool for it live in `codex-home-lock.mjs`; this module owns only the
// lock's name and its blocking wait policy. Callers here do bounded synchronous file work, so
// blocking the loop while waiting is acceptable; a caller that awaits the network must not.

import fs from 'node:fs'
import path from 'node:path'

import {
  isLockHeldElsewhere, openExclusiveLock, validateLockDescriptor,
} from './codex-home-lock.mjs'

const WAIT_WORD = new Int32Array(new SharedArrayBuffer(4))
const LOCK_NAME = '.mechanician-mcp-config.lock'
const LOCK_LABEL = 'Codex MCP configuration lock'

function openExclusive(lockPath) {
  return openExclusiveLock(lockPath)
}

function validateDescriptor(descriptor) {
  validateLockDescriptor(descriptor, LOCK_LABEL)
}

export function withCodexMcpConfigLock(codexHome, work, {
  now = Date.now,
  waitMs = 15_000,
} = {}) {
  if (process.platform !== 'darwin') {
    throw new Error('Codex MCP configuration locking requires macOS O_EXLOCK.')
  }
  fs.mkdirSync(codexHome, { recursive: true })
  const lockPath = path.join(codexHome, LOCK_NAME)
  const deadline = now() + waitMs
  let descriptor = null
  while (descriptor === null) {
    if (now() >= deadline) throw new Error('Codex MCP configuration lock timed out.')
    try {
      descriptor = openExclusive(lockPath)
      validateDescriptor(descriptor)
    } catch (error) {
      if (descriptor !== null) {
        try { fs.closeSync(descriptor) } catch {}
        descriptor = null
      }
      if (error?.code === 'EINTR') continue
      if (!isLockHeldElsewhere(error)) throw error
      Atomics.wait(WAIT_WORD, 0, 0, 10)
    }
  }
  try {
    const result = work()
    if (result && typeof result.then === 'function') {
      return Promise.resolve(result).finally(() => fs.closeSync(descriptor))
    }
    fs.closeSync(descriptor)
    return result
  } catch (error) {
    fs.closeSync(descriptor)
    throw error
  }
}
