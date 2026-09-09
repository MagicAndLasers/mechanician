/**
 * Deduplicates the expensive secure preparation of extensions. The loader may read several
 * Keychain items and the preparer may refresh OAuth; neither should be repeated for every new
 * conversation when the underlying extensions file is unchanged.
 */
export function createPreparedExtensionsCache({
  fingerprint,
  load,
  prepare,
  ttlMs = 5 * 60_000,
  now = () => Date.now(),
  clone = (value) => structuredClone(value),
} = {}) {
  if (typeof fingerprint !== 'function' || typeof load !== 'function'
      || typeof prepare !== 'function') {
    throw new TypeError('prepared extension cache requires fingerprint, load, and prepare')
  }

  let generation = 0
  let cached = null
  let inFlight = null

  function currentFingerprint() {
    try { return String(fingerprint()) } catch { return 'unavailable' }
  }

  async function get({ force = false } = {}) {
    const key = currentFingerprint()
    const at = now()
    if (!force && cached?.key === key && at - cached.preparedAt < ttlMs) {
      return clone(cached.value)
    }
    if (!force && inFlight?.key === key) return clone(await inFlight.promise)

    const ownGeneration = generation
    const promise = Promise.resolve()
      .then(() => load())
      .then((loaded) => prepare(loaded))
    const entry = { key, generation: ownGeneration, promise }
    inFlight = entry
    try {
      const value = await promise
      if (generation === ownGeneration && currentFingerprint() === key) {
        cached = { key, value, preparedAt: now() }
      }
      return clone(value)
    } finally {
      if (inFlight === entry) inFlight = null
    }
  }

  function invalidate() {
    generation++
    cached = null
    inFlight = null
  }

  return Object.freeze({ get, invalidate })
}
