// The Bedrock lane's model list, taken from the account instead of shipped.
//
// This exists because a shipped list was wrong three times in a row, each time from a source that
// looked authoritative:
//   `claude-opus-4-8`                  Anthropic's own id. Bedrock has never heard of it.
//   `us.anthropic.claude-opus-4-8-v1:0`  guessed from the inference-profile naming convention.
//                                        No such profile exists.
//   `anthropic.claude-opus-4-8`        read off list-foundation-models. Invoking it fails with
//                                      "on-demand throughput isn't supported" — a bare foundation
//                                      id is not invokable for the current generation.
// The invokable id is a CROSS-REGION INFERENCE PROFILE, and which ones exist differs by account and
// region. No list we could ship would be right for everyone, so ask.
//
// Access is granted per model family, so a profile existing does NOT mean this account can invoke
// it. That distinction is preserved rather than flattened: the catalog reports what the account
// can address, and a configuration still declares what it actually carries.

/// Anthropic model families, newest first, with the label Mechanician shows. Matched against a
/// profile id, so this decides PRESENTATION only — never which models exist.
const FAMILY_LABELS = [
  [/claude-opus-5/, 'Opus 5'],
  [/claude-opus-4-8/, 'Opus 4.8'],
  [/claude-opus-4-7/, 'Opus 4.7'],
  [/claude-opus-4-6/, 'Opus 4.6'],
  [/claude-opus-4-5/, 'Opus 4.5'],
  [/claude-opus-4-1/, 'Opus 4.1'],
  [/claude-fable-5-1/, 'Fable 5.1'],
  [/claude-fable-5/, 'Fable 5'],
  [/claude-sonnet-5/, 'Sonnet 5'],
  [/claude-sonnet-4-6/, 'Sonnet 4.6'],
  [/claude-sonnet-4-5/, 'Sonnet 4.5'],
  [/claude-sonnet-4/, 'Sonnet 4'],
  [/claude-haiku-4-5/, 'Haiku 4.5'],
  [/claude-3-sonnet/, 'Claude 3 Sonnet'],
  [/claude-3-haiku/, 'Claude 3 Haiku'],
]

/// Generation ordering for the cold-start default. Deliberately NOT "newest wins": a managed or
/// personal deployment is granted access per family, and the newest profile an account can address
/// is often one it cannot yet invoke. 4.8 leads for the same reason it leads on Vertex.
const PREFERRED_ORDER = [
  'Opus 4.8', 'Opus 5', 'Sonnet 5', 'Fable 5', 'Fable 5.1', 'Sonnet 4.6', 'Haiku 4.5',
  'Opus 4.7', 'Opus 4.6', 'Opus 4.5', 'Sonnet 4.5', 'Opus 4.1', 'Sonnet 4',
  'Claude 3 Sonnet', 'Claude 3 Haiku',
]

function labelFor(profileId) {
  for (const [pattern, label] of FAMILY_LABELS) {
    if (pattern.test(profileId)) return label
  }
  return null
}

/// A `global.` profile routes anywhere the model is served; `us.`/`eu.`/`apac.` are regional. When
/// an account has both for one family, prefer `global.` — it is the one that keeps working when a
/// region is busy, and it is what verified successfully against a live account.
function scopeRank(profileId) {
  if (profileId.startsWith('global.')) return 0
  if (profileId.startsWith('us.')) return 1
  return 2
}

/**
 * Normalize `ListInferenceProfiles` into Mechanician catalog entries.
 *
 * Shape is the API's own, captured from a live account rather than guessed:
 *   { inferenceProfileSummaries: [ { inferenceProfileId, inferenceProfileName, description,
 *                                    status, type, models: [{ modelArn }] } ] }
 *
 * Only ACTIVE Anthropic profiles survive. An unrecognized family is KEPT with its id as the label —
 * a model Anthropic ships after this build must still be selectable, which is the entire point of
 * asking the account instead of shipping a list.
 */
export function normalizeBedrockCatalog(response, { maximum = 64 } = {}) {
  const summaries = Array.isArray(response?.inferenceProfileSummaries)
    ? response.inferenceProfileSummaries : []
  const seen = new Set()
  const entries = []

  for (const summary of summaries) {
    const id = typeof summary?.inferenceProfileId === 'string'
      ? summary.inferenceProfileId.trim() : ''
    if (!id || seen.has(id)) continue
    if (!/(^|\.)anthropic\./.test(id)) continue
    // A profile that is not ACTIVE cannot serve a turn; offering it would be offering a failure.
    if (summary.status && summary.status !== 'ACTIVE') continue
    seen.add(id)
    const label = labelFor(id)
    entries.push({
      id,
      label: label || summary.inferenceProfileName || id,
      description: typeof summary.description === 'string' ? summary.description : '',
      family: label,
      scopeRank: scopeRank(id),
      // Bedrock reports no effort or capability metadata, and inventing some would be a guess
      // dressed as discovery.
      efforts: [],
      capabilities: [],
      isDefault: false,
    })
    if (entries.length >= maximum) break
  }

  // One row per family, preferring the broadest scope, then ordered so the cold-start default is
  // the conservative generation rather than the newest id the account happens to list.
  const byFamily = new Map()
  for (const entry of entries) {
    const key = entry.family || entry.id
    const existing = byFamily.get(key)
    if (!existing || entry.scopeRank < existing.scopeRank) byFamily.set(key, entry)
  }
  const ordered = [...byFamily.values()].sort((a, b) => {
    const ai = PREFERRED_ORDER.indexOf(a.family)
    const bi = PREFERRED_ORDER.indexOf(b.family)
    if (ai !== bi) return (ai < 0 ? Number.MAX_SAFE_INTEGER : ai) - (bi < 0 ? Number.MAX_SAFE_INTEGER : bi)
    return a.id.localeCompare(b.id)
  })
  if (ordered.length) ordered[0].isDefault = true
  return ordered.map(({ scopeRank: _scope, family: _family, ...entry }) => entry)
}
