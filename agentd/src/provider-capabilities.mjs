// Provider capability evidence deliberately keeps upstream availability separate from what
// Mechanician's current adapter implements. This module is pure and transport-independent; agentd's
// NDJSON request/event wiring can consume it without putting account identity or credentials on wire.

export const PROVIDER_CAPABILITY_ADAPTER_REVISION = 'provider-capabilities-v2'

export const PROVIDER_CAPABILITY_LIMITS = Object.freeze({
  capabilities: 128,
  idCharacters: 96,
  valueCharacters: 512,
})

const KNOWN_CAPABILITIES = new Map([
  ['effort', { id: 'reasoning_effort', symmetry: 'symmetric' }],
  ['ultra', { id: 'ultra', symmetry: 'providerSpecific' }],
  ['adaptive_thinking', { id: 'adaptive_thinking', symmetry: 'partial' }],
  ['fast_mode', { id: 'fast_mode', symmetry: 'providerSpecific' }],
  ['auto_mode', { id: 'auto_mode', symmetry: 'partial' }],
])

function bounded(value, maximum = PROVIDER_CAPABILITY_LIMITS.valueCharacters) {
  if (typeof value !== 'string') return ''
  return value.replace(/[\u0000-\u001f\u007f]/g, ' ').trim().slice(0, maximum)
}

function capabilityID(value) {
  const normalized = bounded(value, PROVIDER_CAPABILITY_LIMITS.idCharacters)
    .toLowerCase()
    .replace(/[^a-z0-9._-]+/g, '_')
    .replace(/^_+|_+$/g, '')
  return normalized || ''
}

function stringList(values, maximum = 32) {
  if (!Array.isArray(values)) return []
  return [...new Set(values.map((value) => bounded(value, 64).toLowerCase()).filter(Boolean))]
    .slice(0, maximum)
}

function evidence(source, operation, revision = null) {
  return {
    source,
    operation: bounded(operation),
    ...(revision ? { revision: bounded(revision, 128) } : {}),
  }
}

function record({
  id,
  providerAvailability = 'unknown',
  mechanicianSupport = 'unimplemented',
  symmetry = 'unclassified',
  operation = null,
  constraints = {},
  disclosures = {},
  source,
  evidenceOperation,
  evidenceRevision = null,
}) {
  return {
    id,
    providerAvailability,
    mechanicianSupport,
    symmetry,
    ...(operation ? { operation } : {}),
    constraints,
    disclosures,
    evidence: evidence(source, evidenceOperation, evidenceRevision),
  }
}

function modelCatalogEvidenceSource(provider) {
  // Claude SDK supportedModels() and Codex App Server model/list return model capability metadata.
  // OpenAI GET /models does not: its current efforts/capability list is Mechanician's static adapter
  // allowlist, so it must never be represented as provider-reported truth.
  return provider === 'openai' ? 'adapterStatic' : 'providerResponse'
}

function normalizedCatalogCapabilities({ provider, authMode, modelEntry }) {
  const rawCapabilities = stringList(modelEntry?.capabilities, PROVIDER_CAPABILITY_LIMITS.capabilities)
  const efforts = stringList(modelEntry?.efforts)
  const source = modelCatalogEvidenceSource(provider)
  const providerAvailability = source === 'providerResponse' ? 'available' : 'unknown'
  const results = []

  for (const raw of rawCapabilities) {
    const known = KNOWN_CAPABILITIES.get(raw)
    const id = known?.id || `provider.${capabilityID(raw)}`
    if (!id || id === 'provider.') continue
    const implemented = id === 'reasoning_effort'
      || (id === 'ultra' && provider === 'codex' && authMode === 'subscription')
    results.push(record({
      id,
      providerAvailability,
      mechanicianSupport: implemented ? 'implemented' : 'unimplemented',
      symmetry: known?.symmetry || 'unclassified',
      operation: implemented
        ? (provider === 'codex' ? 'turn/start.effort' : 'query.options.effort')
        : null,
      constraints: {
        ...(bounded(modelEntry?.id, 256) ? { model: bounded(modelEntry.id, 256) } : {}),
        ...(id === 'reasoning_effort' && efforts.length ? { levels: efforts.join(',') } : {}),
      },
      source,
      evidenceOperation: provider === 'codex'
        ? 'model/list'
        : provider === 'anthropic'
          ? 'supportedModels'
          : 'normalizeOpenAICatalog',
      evidenceRevision: PROVIDER_CAPABILITY_ADAPTER_REVISION,
    }))
  }

  // Older/current catalog shapes can carry efforts without the redundant `effort` capability.
  if (efforts.length && !results.some((item) => item.id === 'reasoning_effort')) {
    results.push(record({
      id: 'reasoning_effort',
      providerAvailability,
      mechanicianSupport: 'implemented',
      symmetry: 'symmetric',
      operation: provider === 'codex' ? 'turn/start.effort' : 'query.options.effort',
      constraints: {
        ...(bounded(modelEntry?.id, 256) ? { model: bounded(modelEntry.id, 256) } : {}),
        levels: efforts.join(','),
      },
      source,
      evidenceOperation: provider === 'codex'
        ? 'model/list'
        : provider === 'anthropic'
          ? 'supportedModels'
          : 'normalizeOpenAICatalog',
      evidenceRevision: PROVIDER_CAPABILITY_ADAPTER_REVISION,
    }))
  }

  return { results, efforts }
}

/// Normalize only evidence that the current Mechanician adapters can defend today. Capabilities such
/// as compaction, checkpoint/rewind, hosted tools, and provider-native permission profiles remain
/// intentionally absent until their adapters query stable provider surfaces.
export function currentProviderCapabilities({ provider, authMode, modelEntry = {} }) {
  if (!['anthropic', 'codex', 'openai'].includes(provider)) {
    throw new Error(`Unsupported provider capability route: ${bounded(provider) || 'unknown'}`)
  }
  // Vertex is a first-class Claude route (FR-103). Rejecting it here used to fail the WHOLE
  // capability diagnostic for an enterprise account, which reads as "capabilities are broken"
  // rather than "these previews are unavailable on this route" — the opposite of truthful.
  if (!['subscription', 'apikey', 'vertex'].includes(authMode)) {
    throw new Error(`Unsupported provider capability auth mode: ${bounded(authMode) || 'unknown'}`)
  }
  if (authMode === 'vertex' && provider !== 'anthropic') {
    throw new Error(`Unsupported provider capability route: ${bounded(provider)}/vertex`)
  }

  const { results, efforts } = normalizedCatalogCapabilities({ provider, authMode, modelEntry })

  if (provider === 'anthropic') {
    results.push(record({
      id: 'prompt_suggestions',
      providerAvailability: 'available',
      mechanicianSupport: 'implemented',
      symmetry: 'providerSpecific',
      operation: 'query.options.promptSuggestions',
      source: 'providerContract',
      evidenceOperation: 'Claude Agent SDK promptSuggestions',
      evidenceRevision: PROVIDER_CAPABILITY_ADAPTER_REVISION,
    }))
    results.push(record({
      id: 'turn_guidance',
      providerAvailability: 'available',
      mechanicianSupport: 'implemented',
      symmetry: 'symmetric',
      operation: 'streaming_input.priority_next',
      source: 'providerContract',
      evidenceOperation: 'Claude Agent SDK streaming input',
      evidenceRevision: PROVIDER_CAPABILITY_ADAPTER_REVISION,
    }))
    // ── Opus 5 platform surfaces (plan Phase 0, O5-004) ──
    //
    // Each is reported truthfully rather than optimistically: provider availability and Mechanician
    // support move independently, so a UI that gates on these can never offer a control this
    // adapter cannot honor. Advisor, Fast mode, and configurable safety fallback are documented as
    // unavailable on Vertex, so that route gets an explicit `unavailable` — an explicit no is more
    // useful to the picker than an absent record it would have to interpret.
    const previewAvailability = authMode === 'vertex' ? 'unavailable' : 'experimental'

    results.push(record({
      id: 'advisor',
      providerAvailability: previewAvailability,
      // Phase 3 flips this to `implemented` once the request mapping, activity row, and usage
      // receipt exist. Until then the option is typed by the SDK but unreachable in the product.
      mechanicianSupport: 'unimplemented',
      symmetry: 'providerSpecific',
      constraints: {
        ...(bounded(modelEntry?.id, 256) ? { model: bounded(modelEntry.id, 256) } : {}),
        advisorModel: 'claude-opus-5',
      },
      disclosures: {
        // The advisor's answer is encrypted/redacted for the client, so Mechanician can report that
        // a consultation happened and its usage — never invented explanatory content.
        content: 'encryptedRedacted',
        cost: 'premiumAdvisorTokens',
      },
      source: 'providerContract',
      evidenceOperation: 'Claude Agent SDK settings.advisorModel',
      evidenceRevision: PROVIDER_CAPABILITY_ADAPTER_REVISION,
    }))

    results.push(record({
      id: 'safety_refusal_fallback',
      providerAvailability: previewAvailability,
      mechanicianSupport: 'unimplemented',
      symmetry: 'providerSpecific',
      constraints: {
        // Deliberately recorded: the SDK's operational `fallbackModel` covers overloaded/unavailable
        // models and is NOT this capability. Conflating them would let an outage look like a
        // classifier refusal in the transcript.
        distinctFrom: 'operational_fallback',
      },
      source: 'providerContract',
      evidenceOperation: 'Claude Agent SDK model_refusal_fallback',
      evidenceRevision: PROVIDER_CAPABILITY_ADAPTER_REVISION,
    }))

    results.push(record({
      id: 'refusal_supersession',
      // The event contract exists in the pinned SDK on every Claude lane, including Vertex: the
      // daemon may RECEIVE a supersession/refusal regardless of whether the route lets the user
      // configure fallback. Handling it is not optional, which is why it carries no user control.
      providerAvailability: 'available',
      // Phase 1 flips this to `implemented` with the canonical retraction reducer.
      mechanicianSupport: 'unimplemented',
      symmetry: 'providerSpecific',
      disclosures: { control: 'none' },
      source: 'providerContract',
      evidenceOperation: 'Claude Agent SDK assistant.supersedes',
      evidenceRevision: PROVIDER_CAPABILITY_ADAPTER_REVISION,
    }))

    if (authMode === 'vertex') {
      // The model catalog is authoritative for availability, but Fast mode is documented as
      // first-party-only. If an enterprise catalog ever reported it, this explicit record wins the
      // deduplication below so the app cannot offer a Fast control on a route that lacks it.
      results.push(record({
        id: 'fast_mode',
        providerAvailability: 'unavailable',
        mechanicianSupport: 'unimplemented',
        symmetry: 'providerSpecific',
        constraints: {
          ...(bounded(modelEntry?.id, 256) ? { model: bounded(modelEntry.id, 256) } : {}),
        },
        source: 'providerContract',
        evidenceOperation: 'Claude on Vertex route documentation',
        evidenceRevision: PROVIDER_CAPABILITY_ADAPTER_REVISION,
      }))
    }

    if (efforts.includes('xhigh')) {
      // Mechanician has a verified adapter mapping, but supportedModels() does not explicitly report
      // the Ultracode entitlement. Preserve that distinction instead of claiming provider truth.
      results.push(record({
        id: 'claude_ultracode',
        providerAvailability: 'unknown',
        mechanicianSupport: 'implemented',
        symmetry: 'providerSpecific',
        operation: 'query.settings.ultracode',
        constraints: { requiresEffort: 'xhigh' },
        source: 'adapterStatic',
        evidenceOperation: `Claude ${authMode} adapter`,
        evidenceRevision: PROVIDER_CAPABILITY_ADAPTER_REVISION,
      }))
    }
  }

  if (provider === 'codex' && authMode === 'subscription') {
    results.push(record({
      id: 'native_review',
      providerAvailability: 'available',
      mechanicianSupport: 'implemented',
      symmetry: 'providerSpecific',
      operation: 'review/start',
      constraints: {
        target: 'uncommittedChanges',
        delivery: 'inline',
      },
      disclosures: {
        output: 'providerAuthored',
      },
      source: 'providerContract',
      evidenceOperation: 'Codex App Server review/start',
      evidenceRevision: PROVIDER_CAPABILITY_ADAPTER_REVISION,
    }))
    results.push(record({
      id: 'turn_guidance',
      providerAvailability: 'available',
      mechanicianSupport: 'implemented',
      symmetry: 'symmetric',
      operation: 'turn/steer',
      source: 'providerContract',
      evidenceOperation: 'Codex App Server turn/steer',
      evidenceRevision: PROVIDER_CAPABILITY_ADAPTER_REVISION,
    }))
  }

  const deduplicated = new Map()
  for (const item of results) deduplicated.set(item.id, item)
  return {
    adapterRevision: PROVIDER_CAPABILITY_ADAPTER_REVISION,
    capabilities: [...deduplicated.values()]
      .slice(0, PROVIDER_CAPABILITY_LIMITS.capabilities)
      .sort((left, right) => left.id.localeCompare(right.id)),
  }
}
