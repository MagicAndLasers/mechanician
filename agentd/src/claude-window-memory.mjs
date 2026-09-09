/**
 * Remembers the context window the provider ACTUALLY served, per model, for one route.
 *
 * `effectiveClaudeContextWindow` is an assumption derived from model id and route. It has to be,
 * because the oversized-skill decision is made before the turn runs and there is nothing to measure
 * yet. But the provider does report the real denominator on its terminal result
 * (`modelUsage[].contextWindow`, read by `claudeResultContextUsage`), on every route including
 * Vertex where the `getContextUsage()` preflight is bypassed entirely. Until now that number was
 * used once for the fill meter and then thrown away, so every turn re-derived a guess next to a
 * measurement it already had.
 *
 * This is a CACHE, not an authority. Deleting the file costs one turn of guessing and nothing else,
 * so it lives beside the route's Claude config rather than in library.db, and every read and write
 * fails soft: a measurement that cannot be loaded or stored must never block a turn.
 *
 * Why it matters concretely: a managed tenant profile can declare a model this build has no static
 * fact for, such as the Vertex `claude-opus-4-8[1m]` entry whose real 1M window was confirmed on
 * 2026-08-13. Guessing that lane's window wrong is expensive in both directions. Too low re-demotes
 * skills the lane can seat; too high seats a payload that cannot fit and sends the session into
 * repeated multi-minute compaction.
 */

/// Beyond this age a measurement is discarded rather than trusted. A served window can change under
/// us (an entitlement is granted or withdrawn, a provider upgrades a deployment), and a cache with
/// no expiry would carry the old answer indefinitely for a model the user rarely picks. Every
/// completed turn re-records, so an actively used model never expires in practice.
export const CLAUDE_WINDOW_MEASUREMENT_MAX_AGE_MS = 30 * 24 * 60 * 60_000

/// Bounded so a route that cycles through many model ids cannot grow the file without limit. The
/// oldest observation is evicted first, which keeps the models actually in use.
const DEFAULT_MAXIMUM_ENTRIES = 64

const FILE_VERSION = 1

function normalizedModelID(value) {
  return typeof value === 'string' ? value.trim().toLowerCase() : ''
}

/// Deliberately strict about the TYPE, not just the value. Both sources are genuine numbers (the
/// SDK's `modelUsage[].contextWindow`, and the file this module wrote itself), so a string here
/// means something upstream changed shape. Coercing it would let that change through silently and
/// a wrong window is expensive in both directions.
function positiveWindow(value) {
  return typeof value === 'number' && Number.isSafeInteger(value) && value > 0 ? value : 0
}

/**
 * @param readText  () => string|null   Reads the backing file. May throw; treated as "no memory".
 * @param writeText (text) => void      Persists the backing file. May throw; treated as "not kept".
 */
export function createClaudeWindowMemory({
  readText = () => null,
  writeText = () => {},
  now = () => Date.now(),
  maximumEntries = DEFAULT_MAXIMUM_ENTRIES,
  maxAgeMs = CLAUDE_WINDOW_MEASUREMENT_MAX_AGE_MS,
} = {}) {
  const boundedMaximumEntries = Math.max(1, Math.floor(Number(maximumEntries) || 1))
  const boundedMaxAgeMs = Math.max(0, Math.floor(Number(maxAgeMs) || 0))
  /** @type {Map<string, {window: number, observedAt: number}>} */
  let models = new Map()
  let loaded = false

  function load() {
    if (loaded) return
    loaded = true
    let parsed = null
    try {
      const text = readText()
      if (typeof text !== 'string' || !text.trim()) return
      parsed = JSON.parse(text)
    } catch {
      // A truncated or hand-edited file is indistinguishable from no file, and both mean the same
      // thing here: fall back to the static assumption for one turn and re-measure.
      return
    }
    if (!parsed || typeof parsed !== 'object' || parsed.version !== FILE_VERSION) return
    const entries = parsed.models && typeof parsed.models === 'object' ? parsed.models : {}
    for (const [rawID, rawEntry] of Object.entries(entries)) {
      const id = normalizedModelID(rawID)
      const window = positiveWindow(rawEntry?.window)
      const observedAt = positiveWindow(rawEntry?.observedAt)
      if (!id || !window || !observedAt) continue
      models.set(id, { window, observedAt })
    }
    prune()
  }

  function prune() {
    const at = now()
    if (boundedMaxAgeMs > 0) {
      for (const [id, entry] of models) {
        if (at - entry.observedAt > boundedMaxAgeMs) models.delete(id)
      }
    }
    if (models.size <= boundedMaximumEntries) return
    const ordered = [...models.entries()].sort((a, b) => a[1].observedAt - b[1].observedAt)
    for (const [id] of ordered.slice(0, models.size - boundedMaximumEntries)) models.delete(id)
  }

  function persist() {
    const models_ = {}
    for (const [id, entry] of models) models_[id] = { ...entry }
    try {
      writeText(`${JSON.stringify({ version: FILE_VERSION, models: models_ }, null, 2)}\n`)
    } catch {
      // Losing the write costs a re-measurement next turn. It must never surface as a turn failure.
    }
  }

  /// The measured window for a RESOLVED model id, or null when this route has never completed a
  /// turn on it (or the measurement aged out). Null is the signal to fall back to the assumption,
  /// never a reason to block.
  function get(modelID) {
    load()
    const id = normalizedModelID(modelID)
    if (!id) return null
    const entry = models.get(id)
    if (!entry) return null
    if (boundedMaxAgeMs > 0 && now() - entry.observedAt > boundedMaxAgeMs) {
      models.delete(id)
      return null
    }
    return entry.window
  }

  /// Records what the provider served. Returns true when this changed the stored answer, which is
  /// the signal to tell the app so its picker and downshift warning stop showing a guess.
  ///
  /// A measurement is trusted in BOTH directions. Lower than assumed is the safety case and
  /// obviously must win. Higher than assumed must win too: that is the managed-tenant case where a
  /// route serves a variant this build has no static fact for, and refusing to believe it is
  /// precisely the error that would clamp a real 1M window to 200K.
  function record(modelID, window) {
    load()
    const id = normalizedModelID(modelID)
    const measured = positiveWindow(window)
    if (!id || !measured) return false
    const previous = models.get(id)
    const changed = !previous || previous.window !== measured
    models.set(id, { window: measured, observedAt: now() })
    prune()
    persist()
    return changed
  }

  /// Every live measurement as a plain object, for handing to the app.
  function snapshot() {
    load()
    prune()
    const out = {}
    for (const [id, entry] of models) out[id] = entry.window
    return out
  }

  return Object.freeze({ get, record, snapshot })
}
