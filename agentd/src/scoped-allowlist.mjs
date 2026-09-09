import fs from 'node:fs'
import path from 'node:path'
import { createHash, randomUUID } from 'node:crypto'

const lockWait = new Int32Array(new SharedArrayBuffer(4))

function processIsAlive(pid) {
  if (!Number.isInteger(pid) || pid <= 0) return false
  try { process.kill(pid, 0); return true }
  catch (error) { return error?.code !== 'ESRCH' }
}

// A live critical section here is sub-millisecond, so any lock younger than this cannot belong to
// a crashed holder — never reap within it. Comfortably below withFileLock's 5s acquire timeout.
const REAP_GRACE_MS = 2_000

// Atomically remove a lock ONLY if it still carries the exact owner record we judged stale.
// rename() is atomic, so of several racers exactly one moves this inode aside; the token check then
// guarantees we discard only the stale lock we inspected — never a live lock that replaced it in the
// window between our read and our reap (the lost-update race this closes). Returns true when the
// lock is cleared and acquisition should be retried.
function reapStaleLock(lockFile, expectedToken) {
  const aside = `${lockFile}.reap.${randomUUID()}`
  try {
    fs.renameSync(lockFile, aside)
  } catch (error) {
    return error?.code === 'ENOENT'   // already reaped or released by someone else — just retry
  }
  let reaped
  try { reaped = JSON.parse(fs.readFileSync(aside, 'utf8')) } catch {}
  if (!expectedToken || reaped?.token === expectedToken) {
    try { fs.unlinkSync(aside) } catch {}
    return true
  }
  // We grabbed a different (live) lock that took the stale one's place: restore it so its owner's
  // own release still matches, then back off and retry.
  try { fs.renameSync(aside, lockFile) } catch { try { fs.unlinkSync(aside) } catch {} }
  return false
}

// Several workspace windows can own separate provider daemons. Serialize each remembered-grant
// mutation across those processes so two simultaneous approvals merge instead of last-writer-wins
// clobbering one another. The owner token makes cleanup ABA-safe; a dead owner is recoverable.
function withFileLock(file, body, timeoutMs = 5_000) {
  const lockFile = `${file}.lock`
  const token = randomUUID()
  const deadline = Date.now() + timeoutMs
  let acquired = false
  while (!acquired) {
    try {
      const descriptor = fs.openSync(lockFile, 'wx', 0o600)
      try {
        fs.writeFileSync(descriptor, JSON.stringify({ version: 1, pid: process.pid, token }))
        fs.fsyncSync(descriptor)
      } finally {
        fs.closeSync(descriptor)
      }
      acquired = true
    } catch (error) {
      if (error?.code !== 'EEXIST') throw error
      try {
        const owner = JSON.parse(fs.readFileSync(lockFile, 'utf8'))
        const age = Date.now() - fs.statSync(lockFile).mtimeMs
        // Reap only a lock whose owner is provably dead AND that has aged past any live critical
        // section — then only by token (reapStaleLock), so a live lock that took the dead one's
        // place between this read and the reap can never be deleted. Blind-unlinking here was the
        // lost-update race: a waiter deleted a freshly-acquired live lock, admitting a second holder.
        if (!processIsAlive(Number(owner?.pid)) && age > REAP_GRACE_MS) {
          if (reapStaleLock(lockFile, owner?.token)) continue
        }
      } catch (ownerError) {
        if (ownerError?.code === 'ENOENT') continue
        // A creator can be between exclusive create and writing its owner record. Give it time;
        // only remove an unreadable lock once it is clearly stale, still via the atomic reap.
        try {
          const age = Date.now() - fs.statSync(lockFile).mtimeMs
          if (age > 30_000 && reapStaleLock(lockFile, null)) continue
        } catch {}
      }
      if (Date.now() >= deadline) throw new Error(`timed out locking ${path.basename(file)}`)
      Atomics.wait(lockWait, 0, 0, 10)
    }
  }

  try { return body() }
  finally {
    try {
      const owner = JSON.parse(fs.readFileSync(lockFile, 'utf8'))
      if (owner?.token === token) fs.unlinkSync(lockFile)
    } catch {}
  }
}

function canonicalWorkspace(cwd) {
  const resolved = path.resolve(typeof cwd === 'string' && cwd ? cwd : process.cwd())
  try { return fs.realpathSync.native(resolved) } catch { return resolved }
}

function safeRouteSegment(value) {
  return String(value || 'unknown').replace(/[^a-zA-Z0-9_-]/g, '_')
}

/// Persistent "Always allow" decisions scoped to one provider/account route and one canonical
/// workspace. The previous bare array was shared by every lane and folder, so approving Bash once
/// could silently suppress prompts in unrelated providers after a restart.
export class ScopedAllowlist {
  constructor({ rootDir, provider, authMode }) {
    this.provider = String(provider || 'unknown')
    this.authMode = String(authMode || 'unknown')
    this.routeDir = path.join(
      rootDir,
      'permission-scopes',
      `${safeRouteSegment(this.provider)}-${safeRouteSegment(this.authMode)}`)
    fs.mkdirSync(this.routeDir, { recursive: true })
  }

  tools(cwd) {
    const scope = this.#read(cwd)
    return new Set(scope?.tools || [])
  }

  has(tool, cwd) {
    return typeof tool === 'string' && tool.length > 0 && this.tools(cwd).has(tool)
  }

  add(tool, cwd) {
    if (typeof tool !== 'string' || !tool) return
    const canonical = canonicalWorkspace(cwd)
    const { file } = this.#file(canonical)
    withFileLock(file, () => {
      const tools = this.tools(canonical)
      tools.add(tool)
      this.#write(canonical, tools)
    })
  }

  remove(tool, cwd) {
    const canonical = canonicalWorkspace(cwd)
    const { file } = this.#file(canonical)
    withFileLock(file, () => {
      const tools = this.tools(canonical)
      tools.delete(tool)
      this.#write(canonical, tools)
    })
  }

  snapshot(cwd) {
    return [...this.tools(cwd)].sort()
  }

  #file(cwd) {
    const canonical = canonicalWorkspace(cwd)
    const digest = createHash('sha256').update(canonical).digest('hex')
    return { canonical, file: path.join(this.routeDir, `${digest}.json`) }
  }

  #read(cwd) {
    const { canonical, file } = this.#file(cwd)
    try {
      const parsed = JSON.parse(fs.readFileSync(file, 'utf8'))
      if (parsed?.version !== 1 || parsed.provider !== this.provider
          || parsed.authMode !== this.authMode || parsed.cwd !== canonical
          || !Array.isArray(parsed.tools)) return null
      return {
        ...parsed,
        tools: parsed.tools.filter((tool) => typeof tool === 'string' && tool.length > 0),
      }
    } catch { return null }
  }

  #write(cwd, tools) {
    const { canonical, file } = this.#file(cwd)
    fs.mkdirSync(path.dirname(file), { recursive: true })
    const body = JSON.stringify({
      version: 1,
      provider: this.provider,
      authMode: this.authMode,
      cwd: canonical,
      tools: [...tools].sort(),
    })
    const temporary = `${file}.${process.pid}.${randomUUID()}.tmp`
    fs.writeFileSync(temporary, body, { mode: 0o600 })
    fs.renameSync(temporary, file)
  }
}

export { canonicalWorkspace, withFileLock }
