const CONTROL_CHARACTERS = /[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/g
const PATH_CONTROL_CHARACTERS = /[\u0000-\u001f\u007f]/

export const MODEL_CATALOG_LIMITS = Object.freeze({
  models: 256,
  codexPages: 20,
  claudePendingScopes: 32,
  responseBytes: 1024 * 1024,
  idCharacters: 256,
  labelCharacters: 256,
  descriptionCharacters: 1200,
  // Claude catalog scopes are absolute workspace paths. APFS permits paths well beyond the
  // earlier 1 KiB presentation bound, while 4 KiB still keeps one NDJSON control line bounded.
  scopeCharacters: 4096,
})

// `ultra` is provider-reported by eligible Codex subscription models. Keep it in the catalog so
// the app can expose a capability-gated orchestration control; direct API routes still advertise
// only the efforts their own catalog normalization supplies.
const EFFORT_ORDER = ['none', 'minimal', 'low', 'medium', 'high', 'xhigh', 'max', 'ultra']

/// Effort levels are provider-REPORTED, so `EFFORT_ORDER` is an ORDERING, not a whitelist. It used
/// to be applied as `EFFORT_ORDER.filter(...)`, which dropped any level shipped after this build
/// before the app could ever see it — the first of several places that did the same thing.
/// Unrecognized names are now carried after the known ones, bounded by shape and count so a broken
/// or hostile catalog still cannot put arbitrary text on a menu row.
const EFFORT_NAME_SHAPE = /^[a-z][a-z0-9_-]{0,31}$/
const MAX_REPORTED_EFFORTS = 16

function boundedText(value, maximum, { collapseWhitespace = false } = {}) {
  if (typeof value !== 'string') return ''
  let result = value.replace(CONTROL_CHARACTERS, ' ').trim()
  if (collapseWhitespace) result = result.replace(/\s+/g, ' ')
  return result.slice(0, maximum)
}

function modelID(value) {
  const result = boundedText(value, MODEL_CATALOG_LIMITS.idCharacters, { collapseWhitespace: true })
  return result && !/\s/.test(result) ? result : ''
}

function claudeCatalogLabel(value, resolvedModelID) {
  const label = boundedText(
    value, MODEL_CATALOG_LIMITS.labelCharacters, { collapseWhitespace: true },
  )
  if (!label || !resolvedModelID) return label

  // Claude Code intentionally presents stable aliases such as "Sonnet", while resolvedModel
  // carries the version the alias actually selects. Mechanician is a multi-provider picker, so
  // hiding that version makes a newly available model look unchanged. Enrich only a bare family
  // label; preserve provider-authored labels such as "Default (recommended)" verbatim.
  const parts = resolvedModelID.replace(/\[.*$/, '').split('-')
  if (parts[0] !== 'claude' || parts.length < 3) return label
  const family = parts[1]
  const lowerLabel = label.toLowerCase()
  if (lowerLabel !== family && !lowerLabel.startsWith(`${family} (`)) return label
  const major = /^\d{1,2}$/.test(parts[2] || '') ? parts[2] : ''
  if (!major) return label
  const minor = /^\d{1,2}$/.test(parts[3] || '') ? parts[3] : ''
  const version = minor ? `${major}.${minor}` : major
  return lowerLabel === family
    ? `${label} ${version}`
    : `${label.slice(0, family.length)} ${version}${label.slice(family.length)}`
}

function positiveInteger(value) {
  const number = Number(value)
  return Number.isSafeInteger(number) && number > 0 ? number : 0
}

function claudeContextVariantBase(value) {
  return modelID(value).replace(/\[1m\]$/i, '')
}

// Claude publishes the authoritative context-window denominator only on its terminal result,
// separately from the per-assistant-message usage that supplies the current fill. Normalize those
// two SDK shapes into the provider-neutral context_usage event without guessing from an alias.
export function claudeResultContextUsage(
  result,
  { fallbackTokens = 0, preferredModel = '' } = {},
) {
  const entries = Object.entries(
    result?.modelUsage && typeof result.modelUsage === 'object' ? result.modelUsage : {},
  ).map(([rawID, usage]) => {
    const id = modelID(rawID)
    // Newer runtimes retain the raw route/model key for billing while also naming the canonical
    // serving generation. Prefer the latter for identity joins; the context window below remains
    // the independent discriminator for variants such as `[1m]`.
    const canonicalID = modelID(usage?.canonicalModel) || id
    const contextWindow = positiveInteger(usage?.contextWindow)
    if (!id || !contextWindow) return null
    const measuredTokens = positiveInteger(usage?.inputTokens)
      + positiveInteger(usage?.cacheReadInputTokens)
      + positiveInteger(usage?.cacheCreationInputTokens)
    return { id, canonicalID, contextWindow, measuredTokens }
  }).filter(Boolean)
  if (!entries.length) return null

  const preferredID = modelID(preferredModel)
  // An exact raw result key is the strongest join the SDK provides. Canonical ids, by contrast,
  // may be shared by multiple provider routes or billing rows, so they still require uniqueness.
  let selected = entries.find((entry) => entry.id === preferredID)
  if (!selected && preferredID) {
    const preferredBase = claudeContextVariantBase(preferredID)
    const variantMatches = entries.filter((entry) => (
      entry.canonicalID === preferredID
      || claudeContextVariantBase(entry.id) === preferredBase
      || claudeContextVariantBase(entry.canonicalID) === preferredBase
    ))
    // More than one matching result entry is not a model identity. Fail closed instead of joining
    // the final assistant sample to an arbitrary advisor/fallback/billing row.
    if (variantMatches.length !== 1) return null
    selected = variantMatches[0]
  }
  selected ||= entries.reduce((best, entry) => (
      !best || entry.measuredTokens > best.measuredTokens ? entry : best
    ), null)
  const contextTokens = positiveInteger(fallbackTokens) || selected.measuredTokens
  return {
    contextTokens,
    contextWindow: selected.contextWindow,
    model: selected.canonicalID,
  }
}

function efforts(values) {
  if (!Array.isArray(values)) return []
  const names = new Set(values.map((value) => {
    if (typeof value === 'string') return value.toLowerCase()
    if (value && typeof value === 'object') {
      return String(value.reasoningEffort || value.effort || '').toLowerCase()
    }
    return ''
  }))
  const known = EFFORT_ORDER.filter((name) => names.has(name))
  const placed = new Set(known)
  // Insertion order, so an unfamiliar level appears where the provider put it relative to its peers.
  const unknown = [...names].filter(
    (name) => name && !placed.has(name) && EFFORT_NAME_SHAPE.test(name))
  return [...known, ...unknown].slice(0, MAX_REPORTED_EFFORTS)
}

export function catalogScope(value, fallback = '') {
  return boundedText(value || fallback, MODEL_CATALOG_LIMITS.scopeCharacters)
}

function validatedCatalogPathText(value, field) {
  if (typeof value !== 'string') throw new Error(`Model catalog ${field} must be a string.`)
  if (value.length > MODEL_CATALOG_LIMITS.scopeCharacters) {
    throw new Error(
      `Model catalog ${field} exceeds ${MODEL_CATALOG_LIMITS.scopeCharacters} characters.`,
    )
  }
  if (!value) throw new Error(`Model catalog ${field} is required.`)
  if (value !== value.trim()) {
    throw new Error(`Model catalog ${field} must not contain surrounding whitespace.`)
  }
  if (PATH_CONTROL_CHARACTERS.test(value)) {
    throw new Error(`Model catalog ${field} contains unsupported control characters.`)
  }
  return value
}

export function validatedCatalogScope(value) {
  return validatedCatalogPathText(value, 'scope')
}

export function validatedCatalogCwd(value) {
  return validatedCatalogPathText(value, 'cwd')
}

// Catalog discovery starts a real provider subprocess. Coalesce callers for the same workspace and
// serialize distinct workspaces so a restored window or repeatedly opened picker cannot fan out an
// unbounded set of Claude processes. The finite pending-key bound also contains adversarial clients.
export function createKeyedSerialExecutor({
  maximumPendingKeys = MODEL_CATALOG_LIMITS.claudePendingScopes,
} = {}) {
  const pending = new Map()
  let tail = Promise.resolve()
  return function execute(key, operation) {
    const existing = pending.get(key)
    if (existing) return existing
    if (pending.size >= maximumPendingKeys) {
      return Promise.reject(new Error(
        `Too many model catalog scopes are pending (maximum ${maximumPendingKeys}).`,
      ))
    }
    const predecessor = tail
    const result = (async () => {
      try { await predecessor } catch {}
      return operation()
    })()
    pending.set(key, result)
    tail = result.catch(() => {})
    const cleanup = () => {
      if (pending.get(key) === result) pending.delete(key)
    }
    result.then(cleanup, cleanup)
    return result
  }
}

export function catalogErrorMessage(error, fallback = 'Model catalog is unavailable.') {
  const detail = boundedText(error?.message || String(error || ''), 500, { collapseWhitespace: true })
  return detail || fallback
}

export function normalizeClaudeCatalog(items, { maximum = MODEL_CATALOG_LIMITS.models } = {}) {
  const models = []
  const seen = new Set()
  for (const item of Array.isArray(items) ? items : []) {
    const id = modelID(item?.value)
    if (!id || seen.has(id)) continue
    seen.add(id)
    const supportedEfforts = efforts(item?.supportedEffortLevels)
    const capabilities = []
    if (item?.supportsEffort === true || supportedEfforts.length) capabilities.push('effort')
    if (item?.supportsAdaptiveThinking === true) capabilities.push('adaptive_thinking')
    if (item?.supportsFastMode === true) capabilities.push('fast_mode')
    if (item?.supportsAutoMode === true) capabilities.push('auto_mode')
    const resolvedModelID = modelID(item?.resolvedModel)
    const label = claudeCatalogLabel(item?.displayName, resolvedModelID) || id
    const description = boundedText(
      item?.description, MODEL_CATALOG_LIMITS.descriptionCharacters, { collapseWhitespace: true },
    )
    models.push({
      id,
      label,
      ...(resolvedModelID ? { resolvedModelID } : {}),
      ...(description ? { description } : {}),
      isDefault: false,
      efforts: supportedEfforts,
      capabilities,
    })
    if (models.length === maximum) break
  }
  return {
    models,
    truncated: (Array.isArray(items) ? items.length : 0) > maximum,
  }
}

function normalizeCodexModel(item) {
  if (!item || item.hidden === true) return null
  const id = modelID(item.model || item.id)
  if (!id) return null
  const supportedEfforts = efforts(item.supportedReasoningEfforts)
  const description = boundedText(
    item.description, MODEL_CATALOG_LIMITS.descriptionCharacters, { collapseWhitespace: true },
  )
  return {
    id,
    label: boundedText(
      item.displayName, MODEL_CATALOG_LIMITS.labelCharacters, { collapseWhitespace: true },
    ) || id,
    ...(description ? { description } : {}),
    isDefault: item.isDefault === true,
    efforts: supportedEfforts,
    capabilities: [
      ...(supportedEfforts.length ? ['effort'] : []),
      ...(supportedEfforts.includes('ultra') ? ['ultra'] : []),
    ],
  }
}

export async function collectCodexCatalog(
  requestPage,
  { pageLimit = MODEL_CATALOG_LIMITS.codexPages, modelLimit = MODEL_CATALOG_LIMITS.models } = {},
) {
  const models = []
  const byID = new Map()
  const cursors = new Set()
  let cursor = null
  for (let page = 0; page < pageLimit; page += 1) {
    const result = await requestPage(cursor)
    for (const item of Array.isArray(result?.data) ? result.data : []) {
      const normalized = normalizeCodexModel(item)
      if (!normalized) continue
      const prior = byID.get(normalized.id)
      if (prior) {
        if (normalized.isDefault) prior.isDefault = true
        prior.efforts = efforts([...prior.efforts, ...normalized.efforts])
        prior.capabilities = [
          ...(prior.efforts.length ? ['effort'] : []),
          ...(prior.efforts.includes('ultra') ? ['ultra'] : []),
        ]
        continue
      }
      if (models.length >= modelLimit) {
        throw new Error(`Provider returned more than ${modelLimit} selectable models.`)
      }
      models.push(normalized)
      byID.set(normalized.id, normalized)
    }
    const nextCursor = boundedText(result?.nextCursor, 1024)
    if (!nextCursor) return models
    if (cursors.has(nextCursor)) throw new Error('Provider repeated a model catalog cursor.')
    cursors.add(nextCursor)
    cursor = nextCursor
  }
  throw new Error(`Provider model catalog exceeded ${pageLimit} pages.`)
}

/// How to PRESENT ids we can describe well, and the order to lead with.
///
/// This used to be an allowlist: `/v1/models` was intersected with it, so a model absent from this
/// table could not be selected no matter what the account carried. That made a released build the
/// prerequisite for using anything OpenAI shipped after it, and it is why an account with the whole
/// 5.6 generation available saw a picker that stopped at 5.5 — the generation ships as `-sol`,
/// `-terra` and `-luna`, and only a bare `gpt-5.6` was ever listed here. The account's own catalog
/// is now the authority; this table only supplies nicer copy for the ids we happen to know.
export const OPENAI_PRESENTED_MODELS = Object.freeze([
  {
    id: 'gpt-5.6', label: 'GPT-5.6',
    description: 'General-purpose OpenAI Responses model supported by Mechanician.',
  },
  {
    id: 'gpt-5.5', label: 'GPT-5.5',
    description: 'General-purpose OpenAI Responses model supported by Mechanician.',
  },
  {
    id: 'gpt-5.4', label: 'GPT-5.4',
    description: 'General-purpose OpenAI Responses model supported by Mechanician.',
  },
  {
    id: 'gpt-5.4-pro', label: 'GPT-5.4 Pro',
    description: 'Higher-compute OpenAI Responses model supported by Mechanician.',
  },
  {
    id: 'gpt-5.3-codex', label: 'GPT-5.3 Codex',
    description: 'Coding-focused OpenAI Responses model supported by Mechanician.',
  },
  {
    id: 'gpt-5-mini', label: 'GPT-5 mini',
    description: 'Smaller OpenAI Responses model supported by Mechanician.',
  },
])

// The Responses lane sends text turns. Everything OpenAI lists under one of these markers is a
// different modality or a different API surface, and offering it would produce a row whose every
// turn fails. Matching on the marker rather than on an exact id keeps a NEW audio or image model
// out without needing this list to have heard of it.
const OPENAI_NON_RESPONSES_MARKERS = Object.freeze([
  'audio', 'realtime', 'transcribe', 'tts', 'whisper', 'embedding', 'moderation',
  'image', 'dall-e', 'instruct',
])
// Reasoning and chat families. `o1`/`o3`-style ids do not begin with `gpt-`, so they need their own
// clause; anything outside both shapes is not a Responses chat model.
const OPENAI_RESPONSES_FAMILY = /^(gpt-|o\d)/
const OPENAI_DATED_SNAPSHOT = /^(.*)-\d{4}-\d{2}-\d{2}$/

/// Compare ids so `gpt-5.10` sorts above `gpt-5.9`. Plain lexicographic ordering puts a two-digit
/// minor version underneath every single-digit one, which is the wrong answer the first time a
/// generation reaches ten.
function compareModelIDs(left, right) {
  const parts = (value) => value.split(/(\d+)/).filter(Boolean)
  const a = parts(left)
  const b = parts(right)
  for (let index = 0; index < Math.max(a.length, b.length); index += 1) {
    const x = a[index]
    const y = b[index]
    if (x === undefined) return 1
    if (y === undefined) return -1
    if (x === y) continue
    const numeric = /^\d+$/.test(x) && /^\d+$/.test(y)
    // Newest first, so a fresh generation leads the section it is added to.
    if (numeric) return Number(y) - Number(x)
    return x < y ? 1 : -1
  }
  return 0
}

function isSelectableOpenAIModel(id) {
  if (!OPENAI_RESPONSES_FAMILY.test(id)) return false
  return !OPENAI_NON_RESPONSES_MARKERS.some((marker) => id.includes(marker))
}

/// `GPT-5.6 Sol` from `gpt-5.6-sol`. Used only for ids this build has never heard of, so a model
/// released after it still reads as a name rather than as a raw identifier.
function derivedOpenAILabel(id) {
  return id
    .split('-')
    .map((part, index) => {
      if (index === 0 && part === 'gpt') return 'GPT'
      if (/^\d/.test(part)) return part
      return part.charAt(0).toUpperCase() + part.slice(1)
    })
    .join(' ')
    .replace('GPT ', 'GPT-')
}

export function normalizeOpenAICatalog(items) {
  const available = new Set(
    (Array.isArray(items) ? items : []).map((item) => modelID(item?.id)).filter(Boolean),
  )
  const selectable = [...available].filter(isSelectableOpenAIModel).filter((id) => {
    // A dated snapshot beside its own alias is the same model twice. Keep the alias, which is what
    // the account will keep pointing at; keep the snapshot when it is the only way to reach it.
    const base = OPENAI_DATED_SNAPSHOT.exec(id)?.[1]
    return !base || !available.has(base)
  })
  const presented = new Map(OPENAI_PRESENTED_MODELS.map((entry) => [entry.id, entry]))
  const known = OPENAI_PRESENTED_MODELS
    .filter((entry) => selectable.includes(entry.id))
    .map((entry) => entry.id)
  const discovered = selectable
    .filter((id) => !presented.has(id))
    .sort(compareModelIDs)
  return [...known, ...discovered].map((id) => ({
    id,
    label: presented.get(id)?.label || derivedOpenAILabel(id),
    description: presented.get(id)?.description || 'Reported by your OpenAI account.',
    isDefault: false,
    efforts: ['low', 'medium', 'high', 'xhigh'],
    capabilities: ['effort'],
  }))
}

async function responseBytes(response, limit) {
  if (response.body?.getReader) {
    const reader = response.body.getReader()
    const chunks = []
    let total = 0
    try {
      while (true) {
        const { done, value } = await reader.read()
        if (done) break
        const bytes = value instanceof Uint8Array ? value : new Uint8Array(value)
        total += bytes.byteLength
        if (total > limit) {
          try { await reader.cancel() } catch {}
          throw new Error('OpenAI model catalog response was too large.')
        }
        chunks.push(bytes)
      }
    } finally {
      try { reader.releaseLock?.() } catch {}
    }
    const joined = new Uint8Array(total)
    let offset = 0
    for (const chunk of chunks) {
      joined.set(chunk, offset)
      offset += chunk.byteLength
    }
    return joined
  }
  const bytes = new Uint8Array(await response.arrayBuffer())
  if (bytes.byteLength > limit) throw new Error('OpenAI model catalog response was too large.')
  return bytes
}

export async function fetchOpenAIModelCatalog({
  fetchImpl = fetch,
  baseURL,
  apiKey,
  timeoutMilliseconds = 15000,
  responseLimit = MODEL_CATALOG_LIMITS.responseBytes,
}) {
  if (!apiKey) throw new Error('OpenAI API key is not configured.')
  const controller = new AbortController()
  const timer = setTimeout(() => controller.abort(), timeoutMilliseconds)
  try {
    const response = await fetchImpl(`${String(baseURL).replace(/\/$/, '')}/models`, {
      method: 'GET',
      headers: { Authorization: `Bearer ${apiKey}` },
      signal: controller.signal,
    })
    if (!response?.ok) {
      throw new Error(`OpenAI model catalog request failed (${response?.status || 'unknown status'}).`)
    }
    const declaredLength = Number(response.headers?.get?.('content-length'))
    if (Number.isFinite(declaredLength) && declaredLength > responseLimit) {
      throw new Error('OpenAI model catalog response was too large.')
    }
    const bytes = await responseBytes(response, responseLimit)
    let payload
    try { payload = JSON.parse(new TextDecoder().decode(bytes)) }
    catch { throw new Error('OpenAI model catalog returned invalid JSON.') }
    return normalizeOpenAICatalog(payload?.data)
  } catch (error) {
    if (error?.name === 'AbortError') throw new Error('OpenAI model catalog request timed out.')
    throw error
  } finally {
    clearTimeout(timer)
  }
}
