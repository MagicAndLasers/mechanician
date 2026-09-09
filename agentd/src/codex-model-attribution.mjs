function reportedString(value) {
  if (typeof value !== 'string') return null
  const trimmed = value.trim()
  return trimmed || null
}

export const CODEX_THREAD_MODEL_OBSERVATION_MAX_ENTRIES = 512

function canonicalJSONValue(value, inArray = false) {
  if (value === null || typeof value === 'string' || typeof value === 'boolean') return value
  if (typeof value === 'number') return Number.isFinite(value) ? value : null
  if (Array.isArray(value)) {
    return value.map((entry) => canonicalJSONValue(entry, true) ?? null)
  }
  if (value && typeof value === 'object') {
    const normalized = {}
    for (const key of Object.keys(value).sort()) {
      const entry = canonicalJSONValue(value[key], false)
      if (entry !== undefined) normalized[key] = entry
    }
    return normalized
  }
  return inArray ? null : undefined
}

/// Exact, deterministic proof identity for a thread resume request. Object-key order is irrelevant,
/// but every nested value—including complete dynamic-tool descriptions and input schemas—participates
/// in the signature.
export function codexThreadResumeProofSignature(configuration) {
  return JSON.stringify(canonicalJSONValue(configuration))
}

/// Normalize the effective model identity returned by Codex App Server's
/// `thread/start` and `thread/resume` responses. These top-level fields describe
/// what the provider actually selected; the request's model remains only user
/// intent and must not be substituted when either field is absent.
export function codexEffectiveThreadModel(response) {
  const model = reportedString(response?.model)
  if (!model) return null
  const modelProvider = reportedString(response?.modelProvider)
  return {
    model,
    ...(modelProvider ? { modelProvider } : {}),
  }
}

/// Mechanician's provider-neutral root-agent model event. Child-agent model
/// attribution already travels through `workflow_update`; the root uses the same
/// explicit "provider reported this" rule without mutating the conversation's
/// requested model selection.
export function codexRootAgentModelEvent(id, reported) {
  const turnId = reportedString(id)
  const model = reportedString(reported?.model)
  if (!turnId || !model) return null
  const modelProvider = reportedString(reported?.modelProvider)
  return {
    type: 'agent_model',
    id: turnId,
    agentId: 'root',
    model,
    ...(modelProvider ? { modelProvider } : {}),
  }
}

/// Per-provider-thread model truth with a monotonic observation clock. A response may complete
/// after App Server has already sent a settings/reroute notification for the same thread; in that
/// case the response is an older baseline and cannot overwrite the newer notification.
export class CodexThreadModelObservations {
  #revision = 0
  #threads = new Map()
  #maxEntries

  constructor({ maxEntries = CODEX_THREAD_MODEL_OBSERVATION_MAX_ENTRIES } = {}) {
    if (!Number.isSafeInteger(maxEntries) || maxEntries < 1) {
      throw new TypeError('maxEntries must be a positive safe integer')
    }
    this.#maxEntries = maxEntries
  }

  get maxEntries() { return this.#maxEntries }
  get revision() { return this.#revision }
  get size() { return this.#threads.size }

  #state(threadId) {
    const id = reportedString(threadId)
    if (!id) return null
    const state = this.#threads.get(id)
    if (!state) return null
    // Map insertion order is the eviction clock. Reading an active root/child keeps its provider
    // identity hot while abandoned thread observations deterministically age out.
    this.#threads.delete(id)
    this.#threads.set(id, state)
    return state
  }

  get(threadId) {
    return this.#state(threadId)?.latest || null
  }

  /// A model/rerouted notification is explicitly correlated to one provider turn. It enriches that
  /// turn immediately but must not become the claimed identity of the next exact-warm turn.
  getPersistent(threadId) {
    return this.#state(threadId)?.persistent || null
  }

  observe(threadId, reported, source = 'notification') {
    const id = reportedString(threadId)
    const normalized = codexEffectiveThreadModel(reported)
    if (!id || !normalized) return this.get(id)
    const prior = this.#threads.get(id)
    const observation = {
      ...normalized,
      revision: ++this.#revision,
      source,
    }
    const persistent = source === 'model/rerouted'
      ? prior?.persistent || null
      : observation
    this.#threads.delete(id)
    this.#threads.set(id, { latest: observation, persistent })
    while (this.#threads.size > this.#maxEntries) {
      const oldest = this.#threads.keys().next().value
      if (oldest === undefined) break
      this.#threads.delete(oldest)
    }
    return observation
  }

  acceptResponse(threadId, response, requestBaselineRevision) {
    const current = this.get(threadId)
    if (current && current.revision > requestBaselineRevision) return current
    if (!codexEffectiveThreadModel(response)) {
      // A prior configuration's identity is not provider truth for this resume. Preserve only an
      // actually newer notification; otherwise fail closed and force a later provider observation.
      this.delete(threadId)
      return null
    }
    return this.observe(threadId, response, 'response')
  }

  delete(threadId) {
    const id = reportedString(threadId)
    if (id) this.#threads.delete(id)
  }

  clear() {
    this.#threads.clear()
  }
}
