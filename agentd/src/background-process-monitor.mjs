// Low-priority process discovery must never overlap with itself. A setInterval async callback does
// not wait for the previous callback, which turned a slow lsof pass into an unbounded process storm.
// This monitor arms the next timeout only after the current poll settles.

/// Coalesce unchanged process snapshots without losing the first snapshot after a successful Stop.
/// The initial empty list is intentionally quiet. `invalidate()` uses a value no real signature can
/// produce, so the next poll publishes either an empty list (removing a dead row) or the same pid
/// again (when a process ignored SIGTERM and must be offered to the user again).
export function createBackgroundProcessPublicationGate(publish) {
  if (typeof publish !== 'function') throw new TypeError('publish must be a function')
  let lastSignature = ''

  return {
    publish(processes) {
      const signature = processes.map((process) => `${process.pid}:${process.detached}`).join(',')
      if (signature === lastSignature) return false
      lastSignature = signature
      publish(processes)
      return true
    },
    invalidate() {
      lastSignature = null
    },
  }
}

export function createBackgroundProcessMonitor({
  poll,
  publish,
  shouldPoll = () => true,
  intervalMs = 5_000,
  schedule = setTimeout,
  cancel = clearTimeout,
  onError = () => {},
}) {
  if (typeof poll !== 'function') throw new TypeError('poll must be a function')
  if (typeof publish !== 'function') throw new TypeError('publish must be a function')
  if (typeof shouldPoll !== 'function') throw new TypeError('shouldPoll must be a function')

  let stopped = false
  let timer = null
  let activeController = null

  const arm = () => {
    if (stopped) return
    timer = schedule(() => {
      timer = null
      void tick()
    }, intervalMs)
    timer?.unref?.()
  }

  const tick = async () => {
    if (stopped) return
    const controller = new AbortController()
    activeController = controller
    try {
      if (!shouldPoll()) return
      const processes = await poll({ signal: controller.signal })
      if (!stopped) publish(processes)
    } catch (error) {
      if (!stopped && !controller.signal.aborted) {
        try { onError(error) } catch {}
      }
    } finally {
      if (activeController === controller) activeController = null
      arm()
    }
  }

  arm()

  return {
    stop() {
      if (stopped) return
      stopped = true
      if (timer !== null) cancel(timer)
      timer = null
      activeController?.abort(new Error('background process monitor stopped'))
      activeController = null
    },
  }
}
