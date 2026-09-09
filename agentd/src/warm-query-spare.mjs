/**
 * Keep one asynchronously-prepared provider query ready for the most likely next turn.
 *
 * The value returned by `factory` must expose `close()`. A claim transfers ownership to the
 * caller; replacing, mismatching, or explicitly clearing a spare closes it even when preparation
 * is still in flight. This deliberately knows nothing about Claude or turn routing, which keeps
 * the race behavior small and unit-testable.
 */
export function createWarmQuerySpare({
  log = () => {},
  label = 'warm query',
  maxIdleMs = 0,
} = {}) {
  let slot = null

  function closePrepared(prepared) {
    try { prepared?.close?.() } catch (error) {
      log(`${label} close failed: ${error?.message || error}`)
    }
  }

  function dispose(candidate) {
    if (!candidate) return
    if (candidate.expiryTimer) clearTimeout(candidate.expiryTimer)
    candidate.expiryTimer = null
    candidate.promise.then(closePrepared).catch(() => {})
  }

  function clear(reason = 'cleared') {
    const candidate = slot
    if (!candidate) return false
    slot = null
    dispose(candidate)
    log(`${label} ${reason}`)
    return true
  }

  function warm(key, factory) {
    if (typeof key !== 'string' || !key || typeof factory !== 'function') return null
    if (slot?.key === key) return slot.promise

    const previous = slot
    const promise = Promise.resolve().then(factory)
    const candidate = { key, promise, expiryTimer: null }
    slot = candidate
    dispose(previous)

    promise.then(() => {
      if (slot !== candidate || !(maxIdleMs > 0)) return
      candidate.expiryTimer = setTimeout(() => {
        if (slot === candidate) clear('expired while idle')
      }, maxIdleMs)
      candidate.expiryTimer.unref?.()
    }).catch(() => {})
    promise.catch((error) => {
      if (slot === candidate) slot = null
      log(`${label} preparation failed: ${error?.message || error}`)
    })
    return promise
  }

  async function claim(key) {
    const candidate = slot
    if (!candidate) return null
    if (candidate.key !== key) {
      clear('discarded after configuration changed')
      return null
    }
    // Transfer ownership before awaiting. A second claimant must not receive the same one-shot
    // query, and clear() must not close a value the caller now owns.
    slot = null
    if (candidate.expiryTimer) clearTimeout(candidate.expiryTimer)
    candidate.expiryTimer = null
    try {
      return await candidate.promise
    } catch {
      return null
    }
  }

  return {
    warm,
    claim,
    clear,
    get pending() { return slot !== null },
    get key() { return slot?.key ?? null },
  }
}
