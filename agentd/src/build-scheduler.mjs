import fs from 'node:fs'
import path from 'node:path'

// Per-build-root serialization for the build runner.
//
// Each workspace WINDOW is already its own agentd process, so builds in different windows are
// independent. This makes builds WITHIN one agentd safe too: builds at DIFFERENT roots run
// concurrently, and a second build at the SAME root QUEUES behind the active one and starts when it
// finishes — instead of the old single global build slot that returned a fatal `code:-1` an agent
// reads as a build failure. Roots are keyed by realpath so symlinked paths to one tree share a slot.
//
// The scheduler owns only the ordering; the caller owns spawning/emitting. `start()` must call
// `setProc(root, proc)` once it has the child, and `finish(root)` on the child's close/error.
export function createBuildScheduler({ signal = () => {}, realpath = fs.realpathSync } = {}) {
  const byRoot = new Map() // root -> { proc: <child>|null, queue: Array<() => void> }

  // Resolve a directory to a canonical build-root key. Falls back to a lexically-resolved path when
  // the directory does not exist yet (realpath throws), so a missing dir still keys consistently.
  function rootFor(dir, fallback) {
    const base = dir || fallback
    try { return realpath(base) } catch { return path.resolve(base) }
  }

  // Run `start` immediately if the root is idle, else queue it behind that root's active build.
  function schedule(root, start) {
    let entry = byRoot.get(root)
    if (!entry) { entry = { proc: null, queue: [] }; byRoot.set(root, entry) }
    if (entry.proc) entry.queue.push(start)
    else start()
  }

  // Record the spawned child for a root (called from within `start`).
  function setProc(root, proc) {
    const entry = byRoot.get(root)
    if (entry) entry.proc = proc
  }

  // A build at `root` ended (close/error): start the next queued build for that root, or drop the
  // now-empty slot.
  function finish(root) {
    const entry = byRoot.get(root)
    if (!entry) return
    entry.proc = null
    const next = entry.queue.shift()
    if (next) next()
    else byRoot.delete(root)
  }

  // Cancel builds at one root, or all roots when `root` is null (build_cancel carries no cwd today).
  // Drops the queue FIRST so a queued build cannot start after the running one is signalled.
  function cancel(root = null, sig = 'SIGTERM') {
    const roots = root ? [root] : [...byRoot.keys()]
    for (const r of roots) {
      const entry = byRoot.get(r)
      if (!entry) continue
      entry.queue.length = 0
      if (entry.proc) signal(entry.proc, sig)
    }
  }

  // Signal every active build and clear all queues (daemon/provider shutdown).
  function stopAll(sig = 'SIGTERM') {
    for (const entry of byRoot.values()) {
      entry.queue.length = 0
      if (entry.proc) signal(entry.proc, sig)
    }
  }

  // Introspection (used by tests).
  function activeRoots() { return [...byRoot.entries()].filter(([, e]) => e.proc).map(([r]) => r) }
  function queueDepth(root) { return byRoot.get(root)?.queue.length ?? 0 }
  function isActive(root) { return byRoot.get(root)?.proc != null }

  return { rootFor, schedule, setProc, finish, cancel, stopAll, activeRoots, queueDepth, isActive }
}
