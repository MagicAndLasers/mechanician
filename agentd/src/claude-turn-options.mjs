// Claude-only turn configuration, kept pure and transport-independent.
//
// Two jobs, deliberately separated:
//   1. `parseClaudeTurnConfiguration` validates the optional nested `claude` block of a `send`
//      request into a frozen, immutable turn snapshot BEFORE the turn is accepted or a provider is
//      spawned. A malformed or ineligible block fails the request instead of reaching the SDK.
//   2. `buildClaudeQueryOptions` maps that snapshot (plus model/effort/ultracode) to the exact
//      Agent SDK `query()` option surface Mechanician owns: `model`, `effort`, and `settings`, plus
//      the resolved model identity used only for local context accounting.
//
// Living here rather than inline in the 7k-line daemon is what lets tests assert the precise SDK
// options for every preference combination without launching a provider process. The contract that
// matters most: an ABSENT `claude` block must produce byte-identical options to the release that
// predates it, so the foundation can ship with no behavior change at all.

// Provider facts the app has to agree with, generated from shared/provider-facts.json so it cannot
// disagree silently. These were hand-mirrored, with comments here saying "keep the two lists
// identical", and `routesWithoutPreviewSurfaces` drifted anyway.
import {
  millionTokenSuffixUpgrades,
  nativeMillionTokenModels,
  routesWithoutPreviewSurfaces,
  thirdPartyMillionTokenModels,
  thirdPartyModelIDPrefixes,
  thirdPartyRoutes,
} from './generated/provider-facts.mjs'

/// Mechanician's Claude default. Opus 5 promotion is a separate, isolated change (plan Phase 2)
/// gated on the qualification corpus, so this constant stays on 4.8 until that gate passes. Keeping
/// it here gives that phase exactly one place to flip instead of three scattered literals.
export const CLAUDE_DEFAULT_MODEL = 'claude-opus-4-8'

/// The advisor Anthropic documents for the server-side advisor tool. Only ever sent when the
/// conversation explicitly opted in AND the route is eligible.
export const CLAUDE_ADVISOR_MODEL = 'claude-opus-5'

/// Efforts at which Opus 5 rejects disabled thinking. Mechanician never disables thinking today;
/// the invariant exists so a future control cannot silently produce a provider error.
export const THINKING_REQUIRED_EFFORTS = Object.freeze(['xhigh', 'max'])

export const CLAUDE_TURN_OPTION_LIMITS = Object.freeze({
  modelCharacters: 256,
  effortCharacters: 32,
  modeCharacters: 32,
})

const ADVISOR_MODES = new Set(['off', 'automatic'])
const SPEEDS = new Set(['standard', 'fast'])
const REFUSAL_FALLBACK_MODES = new Set(['off', 'providerDefault', 'model'])
const THINKING_MODES = new Set(['adaptive', 'disabled'])

/// Experimental features that must be explicitly enabled before a non-default preference is
/// accepted. Each maps to one dogfood slice of the Opus 5 plan.
export const CLAUDE_EXPERIMENTAL_FEATURES = Object.freeze(['advisor', 'fast', 'refusalFallback'])

/// The all-off snapshot. An absent `claude` block and an explicitly all-default block both resolve
/// to this, so a conversation that has never touched a Claude preference is indistinguishable from
/// one that persisted its defaults.
export const DEFAULT_CLAUDE_TURN_CONFIGURATION = Object.freeze({
  advisor: Object.freeze({ mode: 'off', model: null }),
  speed: 'standard',
  refusalFallback: Object.freeze({ mode: 'off', model: null }),
  thinking: 'adaptive',
})

export class ClaudeTurnOptionError extends Error {
  constructor(message, { field = '', feature = '' } = {}) {
    super(message)
    this.name = 'ClaudeTurnOptionError'
    // Callers surface `message` to the user and `field`/`feature` to developer diagnostics only.
    this.field = field
    this.feature = feature
  }
}

function isPlainObject(value) {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

/// Reject rather than silently truncate: a value too long to be legitimate is a client bug, and
/// quietly trimming a model ID would send a DIFFERENT model than the one requested.
function boundedIdentifier(value, { field, maximum, pattern }) {
  if (typeof value !== 'string') {
    throw new ClaudeTurnOptionError(`${field} must be a string.`, { field })
  }
  const trimmed = value.trim()
  if (!trimmed) throw new ClaudeTurnOptionError(`${field} must not be empty.`, { field })
  if (trimmed.length > maximum) {
    throw new ClaudeTurnOptionError(
      `${field} must be at most ${maximum} characters.`, { field })
  }
  if (!pattern.test(trimmed)) {
    throw new ClaudeTurnOptionError(`${field} contains unsupported characters.`, { field })
  }
  return trimmed
}

// Deliberately permissive about SHAPE and strict about BOUNDS. First-party aliases
// (`claude-opus-5`), legacy context variants (`claude-opus-4-8[1m]`), and Vertex publisher IDs
// (`claude-opus-4-5@20250101`, `publishers/anthropic/models/…`) must all pass through unchanged;
// only control characters and whitespace are refused.
const MODEL_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._:@/\-[\]]*$/
// Effort levels are provider-REPORTED, so this must not be a fixed enum — a level Anthropic ships
// after this build has to keep working. Bound the shape, not the vocabulary.
const EFFORT_PATTERN = /^[a-z][a-z0-9_-]*$/
const MODE_PATTERN = /^[A-Za-z][A-Za-z0-9]*$/

function parseMode(value, { field, allowed }) {
  const mode = boundedIdentifier(value, {
    field,
    maximum: CLAUDE_TURN_OPTION_LIMITS.modeCharacters,
    pattern: MODE_PATTERN,
  })
  if (!allowed.has(mode)) {
    throw new ClaudeTurnOptionError(
      `${field} must be one of: ${[...allowed].join(', ')}.`, { field })
  }
  return mode
}

function parseModel(value, field) {
  return boundedIdentifier(value, {
    field,
    maximum: CLAUDE_TURN_OPTION_LIMITS.modelCharacters,
    pattern: MODEL_PATTERN,
  })
}

function rejectUnknownKeys(raw, allowed, field) {
  for (const key of Object.keys(raw)) {
    if (!allowed.has(key)) {
      throw new ClaudeTurnOptionError(`${field} does not support “${key}”.`, { field })
    }
  }
}

/// Parse the comma-separated dev gate. The APP decides whether to set this at all (a release bundle
/// never does), so agentd only has to honor an explicit list and treat everything else as off.
export function claudeExperimentalFeatures(env = {}) {
  const raw = typeof env.MECHANICIAN_ENABLE_CLAUDE_EXPERIMENTS === 'string'
    ? env.MECHANICIAN_ENABLE_CLAUDE_EXPERIMENTS : ''
  const enabled = new Set()
  for (const part of raw.split(',')) {
    const name = part.trim()
    if (CLAUDE_EXPERIMENTAL_FEATURES.includes(name)) enabled.add(name)
  }
  return enabled
}

function requireFeature(feature, experimental, label) {
  if (experimental.has(feature)) return
  throw new ClaudeTurnOptionError(
    `${label} is not available in this build.`, { field: feature, feature })
}

/// Routes that document no support for the Opus 5 preview surfaces: they fail closed here no matter
/// what a client asks for or which dev gate is enabled. The list is generated
/// (`routesWithoutPreviewSurfaces`) because the copy that used to live here listed only `vertex`
/// while the app withheld the same surfaces on Vertex AND Bedrock — so this function, which its own
/// callers call "the last gate before the wire", was open on two of the three third-party routes.
function requireRouteSupport(authMode, label, field) {
  if (!routesWithoutPreviewSurfaces.has(authMode)) return
  throw new ClaudeTurnOptionError(
    `${label} is not available on this Claude route.`, { field })
}

/// Validate the optional nested `claude` request block into an immutable turn snapshot.
///
/// `provider` is the daemon's lane. A non-Anthropic lane must never carry Claude settings, so a
/// non-empty block there is a client bug and is refused outright rather than dropped — dropping it
/// would let a Codex turn silently ignore a preference the user believes is active.
export function parseClaudeTurnConfiguration(
  raw,
  { provider, authMode = 'apikey', experimental = new Set() } = {},
) {
  if (raw === undefined || raw === null) return DEFAULT_CLAUDE_TURN_CONFIGURATION
  if (!isPlainObject(raw)) {
    throw new ClaudeTurnOptionError('claude must be an object.', { field: 'claude' })
  }
  if (provider !== 'anthropic') {
    if (Object.keys(raw).length > 0) {
      throw new ClaudeTurnOptionError(
        `Claude turn options are not available on the ${provider} lane.`, { field: 'claude' })
    }
    return DEFAULT_CLAUDE_TURN_CONFIGURATION
  }

  rejectUnknownKeys(raw, new Set(['advisor', 'speed', 'refusalFallback', 'thinking']), 'claude')

  let advisor = DEFAULT_CLAUDE_TURN_CONFIGURATION.advisor
  if (raw.advisor !== undefined && raw.advisor !== null) {
    if (!isPlainObject(raw.advisor)) {
      throw new ClaudeTurnOptionError('claude.advisor must be an object.', { field: 'claude.advisor' })
    }
    rejectUnknownKeys(raw.advisor, new Set(['mode', 'model']), 'claude.advisor')
    const mode = raw.advisor.mode === undefined
      ? 'off'
      : parseMode(raw.advisor.mode, { field: 'claude.advisor.mode', allowed: ADVISOR_MODES })
    if (mode === 'off') {
      if (raw.advisor.model !== undefined && raw.advisor.model !== null) {
        throw new ClaudeTurnOptionError(
          'claude.advisor.model requires an active advisor mode.', { field: 'claude.advisor.model' })
      }
    } else {
      requireRouteSupport(authMode, 'The Opus 5 advisor', 'claude.advisor')
      requireFeature('advisor', experimental, 'The Opus 5 advisor')
      const model = raw.advisor.model === undefined || raw.advisor.model === null
        ? CLAUDE_ADVISOR_MODEL
        : parseModel(raw.advisor.model, 'claude.advisor.model')
      advisor = Object.freeze({ mode, model })
    }
  }

  let speed = DEFAULT_CLAUDE_TURN_CONFIGURATION.speed
  if (raw.speed !== undefined && raw.speed !== null) {
    speed = parseMode(raw.speed, { field: 'claude.speed', allowed: SPEEDS })
    if (speed !== 'standard') {
      requireRouteSupport(authMode, 'Fast mode', 'claude.speed')
      requireFeature('fast', experimental, 'Fast mode')
    }
  }

  let refusalFallback = DEFAULT_CLAUDE_TURN_CONFIGURATION.refusalFallback
  if (raw.refusalFallback !== undefined && raw.refusalFallback !== null) {
    if (!isPlainObject(raw.refusalFallback)) {
      throw new ClaudeTurnOptionError(
        'claude.refusalFallback must be an object.', { field: 'claude.refusalFallback' })
    }
    rejectUnknownKeys(raw.refusalFallback, new Set(['mode', 'model']), 'claude.refusalFallback')
    const mode = raw.refusalFallback.mode === undefined
      ? 'off'
      : parseMode(raw.refusalFallback.mode, {
        field: 'claude.refusalFallback.mode', allowed: REFUSAL_FALLBACK_MODES,
      })
    if (mode === 'off') {
      if (raw.refusalFallback.model !== undefined && raw.refusalFallback.model !== null) {
        throw new ClaudeTurnOptionError(
          'claude.refusalFallback.model requires an active fallback mode.',
          { field: 'claude.refusalFallback.model' })
      }
    } else {
      requireRouteSupport(authMode, 'Automatic safety fallback', 'claude.refusalFallback')
      requireFeature('refusalFallback', experimental, 'Automatic safety fallback')
      if (mode === 'model') {
        refusalFallback = Object.freeze({
          mode,
          model: parseModel(raw.refusalFallback.model, 'claude.refusalFallback.model'),
        })
      } else {
        if (raw.refusalFallback.model !== undefined && raw.refusalFallback.model !== null) {
          throw new ClaudeTurnOptionError(
            'claude.refusalFallback.model is only valid with mode “model”.',
            { field: 'claude.refusalFallback.model' })
        }
        refusalFallback = Object.freeze({ mode, model: null })
      }
    }
  }

  let thinking = DEFAULT_CLAUDE_TURN_CONFIGURATION.thinking
  if (raw.thinking !== undefined && raw.thinking !== null) {
    thinking = parseMode(raw.thinking, { field: 'claude.thinking', allowed: THINKING_MODES })
  }

  return Object.freeze({ advisor, speed, refusalFallback, thinking })
}

/// Routes served from a cloud vendor's catalog rather than Anthropic's first-party one. The pinned
/// engine gates a BARE id's 1M window on these routes behind a per-model `native_1m_3p` flag, so
/// they cannot be assumed to match first-party behavior for either model naming or window size.
/// Generated as `thirdPartyRoutes`; see shared/provider-facts.json.

/// Opus 4.8 offers a 1M-token context window through the `[1m]` model variant, so enable it and the
/// agent keeps far more in context. Opus 5 is natively 1M and must pass through UNCHANGED on a
/// first-party route, where suffixing a bare id it already serves at 1M buys nothing.
///
/// Third-party routes always pass through, but NOT because the variant is unavailable there. That
/// was the old rationale and it is measured false: an explicitly named `claude-opus-4-8[1m]` served
/// a confirmed 1M window on a managed Vertex route (2026-08-13), and was the only way that project
/// reached a 1M Opus window at all. What the engine registry withholds on those routes is automatic
/// upgrade eligibility for a BARE id, which is a different question from what the route serves when
/// a variant is named outright.
///
/// The pass-through therefore stands on entitlement, not availability: a 1M variant is enabled per
/// project on these clouds, and synthesizing the suffix here would name a model some other project
/// does not serve, converting a working bare selection into a failing one. A tenant that has the
/// variant declares it in its profile and reaches this function already suffixed, at which point
/// `effectiveClaudeContextWindow` honors it on any route.
export function resolveClaudeModel(model, { authMode = 'apikey', disable1M = false } = {}) {
  if (thirdPartyRoutes.has(authMode)) return model
  if (disable1M) return model
  return millionTokenSuffixUpgrades.has(model) ? `${model}[1m]` : model
}

/// The effort actually sent. An absent effort means "provider default", not Mechanician's historical
/// High default. Ultracode is the sole implicit override because its product contract pins xhigh.
function effectiveEffort({ effort, ultracode }) {
  if (ultracode) return 'xhigh'
  if (typeof effort !== 'string') return null
  const trimmed = effort.trim()
  if (!trimmed) return null
  if (trimmed.length > CLAUDE_TURN_OPTION_LIMITS.effortCharacters
      || !EFFORT_PATTERN.test(trimmed)) {
    throw new ClaudeTurnOptionError('effort is not a supported value.', { field: 'effort' })
  }
  return trimmed
}

/// The 1M model facts and the third-party id qualifiers are generated
/// (`nativeMillionTokenModels`, `thirdPartyMillionTokenModels`, `thirdPartyModelIDPrefixes`).
/// Their rationale, including why `claude-sonnet-5` is the only model that gets 1M on a third-party
/// route and what treating the others as 1M there re-opens, lives with the data in
/// shared/provider-facts.json rather than in one language's comment.
export function canonicalClaudeModelID(id) {
  const base = String(id ?? '').toLowerCase().split('[')[0]
  for (const prefix of thirdPartyModelIDPrefixes) {
    if (base.startsWith(prefix)) return base.slice(prefix.length)
  }
  return base
}

/// The window the RESOLVED model actually gets, which is a property of the model AND the route.
///
/// This is the fact issue 47 turned on. Bare Opus 4.8 reaches 1M only through the `[1m]` variant,
/// and `resolveClaudeModel` deliberately does not apply that variant on a third-party route, so the
/// same BARE id is a 1M lane on a subscription and a 200K lane on Vertex. Anything not positively
/// known to be 1M is treated as 200K, because guessing high is what puts an unfittable payload back
/// in the window, which is exactly what a route-blind answer did for bare Opus 5 on Vertex.
///
/// An id that names `[1m]` outright is the one case that is route-independent, and the ordering
/// below says so on purpose. A caller only holds such an id because something authoritative
/// produced it: a first-party upgrade, or a managed tenant profile declaring the variant it has
/// been granted. Measured on 2026-08-13, a profile-declared `claude-opus-4-8[1m]` served a
/// confirmed 1M window on Vertex. Do not "fix" this short-circuit to consult the route; the
/// third-party lists govern bare ids, and applying them here would silently cut a tenant's real 1M
/// window to 200K and re-demote skills that lane can seat.
///
/// Takes the RESOLVED id (the output of `resolveClaudeModel`), never the requested one.
///
/// This is the ASSUMPTION. `claudeResultContextUsage` reports what the provider actually served,
/// on every route including Vertex; prefer a stored measurement over this function wherever one
/// exists, and fall back here only for a model this install has never completed a turn on.
export function effectiveClaudeContextWindow(resolvedModel, { authMode = 'apikey' } = {}) {
  const id = String(resolvedModel ?? '').toLowerCase()
  if (id.includes('[1m]')) return 1_000_000
  const canonical = canonicalClaudeModelID(id)
  if (!nativeMillionTokenModels.has(canonical)) return 200_000
  if (thirdPartyRoutes.has(authMode)) {
    return thirdPartyMillionTokenModels.has(canonical) ? 1_000_000 : 200_000
  }
  return 1_000_000
}

/// The window to use for a resolved model, together with where the number came from.
///
/// `measured` is what the provider reported serving on a previous completed turn for this exact
/// route and resolved id (see claude-window-memory.mjs). `assumed` is the static derivation above.
/// A measurement wins whenever one exists, in both directions:
///
///   - Lower than assumed is the safety case. A lane we believed was 1M but is really 200K must
///     demote the oversized skills, or the payload cannot fit and the session compacts repeatedly.
///   - Higher than assumed must win too. That is the managed-tenant case, where a profile declares
///     a variant this build carries no static fact for. Refusing the measurement there is what
///     would clamp a real 1M window to 200K and take away a capability the route actually has.
///
/// Callers that need to explain themselves to a person (a log line, a picker row, a downshift
/// warning) should use this rather than `effectiveClaudeContextWindow` directly, so "1M" and "1M,
/// as far as we can tell" stay distinguishable.
export function claudeContextWindowDecision(
  resolvedModel,
  { authMode = 'apikey', measuredWindow = null } = {},
) {
  const measured = Number(measuredWindow)
  if (Number.isSafeInteger(measured) && measured > 0) {
    return { window: measured, source: 'measured' }
  }
  return { window: effectiveClaudeContextWindow(resolvedModel, { authMode }), source: 'assumed' }
}

/// The smallest window that can hold an oversized bundled skill and still leave room for a turn.
/// The `claude-api` payload alone is roughly 200-220K tokens, so a 200K lane cannot seat it at all.
const OVERSIZED_SKILL_MINIMUM_WINDOW = 1_000_000

/// Bundled skills whose reference text cannot fit a 200K context window.
///
/// `claude-api` inlines the full text of its reference documents (about 878KB of source, roughly
/// 200-220K tokens) into a single message when the model invokes it. On a 200K-window model that
/// overflows the window mid-turn, and it cannot be compacted away because the payload lands in the
/// last message group, which compaction always preserves. The turn then dies on a failed
/// compaction with no answer. Demoting it to `user-invocable-only` hides it from the model while
/// keeping `/claude-api` typable, so the capability is budgeted rather than removed.
///
/// Verified against the pinned harness: with this override the skill stays in `supportedCommands()`
/// and the model no longer invokes it. Add a name here only with evidence that its payload cannot
/// fit the smallest window Mechanician ships against.
export const OVERSIZED_BUNDLED_SKILLS = ['claude-api']

/// Build the Claude-owned slice of the SDK `query()` options: `{ model, effort, settings }`.
///
/// Returns `effort: null` when none should be sent, so the caller can omit the key entirely rather
/// than sending an empty string. `settings` key insertion order is stable, and the default case is
/// byte-identical to the pre-refactor daemon EXCEPT for the trailing `skillOverrides` demotion
/// above, which every turn now carries. `allowOversizedSkills: true` restores the older object
/// exactly, which is what the escape hatch is for.
export function buildClaudeQueryOptions({
  model,
  catalogResolvedModel = null,
  effort,
  ultracode = false,
  authMode = 'apikey',
  disable1M = false,
  allowOversizedSkills = false,
  configuration = DEFAULT_CLAUDE_TURN_CONFIGURATION,
  /// Looks up what this route measured for a RESOLVED id on a previous completed turn, or null.
  /// Optional: a caller with no memory wired keeps the pre-existing static behavior exactly.
  lookupMeasuredWindow = null,
} = {}) {
  const requested = model === undefined || model === null || model === ''
    ? CLAUDE_DEFAULT_MODEL
    : parseModel(model, 'model')
  const resolvedEffort = effectiveEffort({ effort, ultracode })

  // Opus 5 rejects thinking disabled at xhigh/max. Fail here — before the provider is spawned — so
  // an unsupported combination can never become a live turn that dies mid-stream.
  if (configuration.thinking === 'disabled'
      && resolvedEffort
      && THINKING_REQUIRED_EFFORTS.includes(resolvedEffort)) {
    throw new ClaudeTurnOptionError(
      `Thinking cannot be disabled at ${resolvedEffort} effort.`, { field: 'claude.thinking' })
  }

  // Defense in depth. `parseClaudeTurnConfiguration` already refuses these on an unsupported route,
  // but the mapping to real SDK settings is the last gate before the wire — a future caller that
  // builds a configuration without parsing one must not be able to leak a preview setting.
  if (configuration.advisor.mode !== 'off') {
    requireRouteSupport(authMode, 'The Opus 5 advisor', 'claude.advisor')
  }
  if (configuration.speed !== 'standard') {
    requireRouteSupport(authMode, 'Fast mode', 'claude.speed')
  }

  const settings = { enableWorkflows: true, precomputeCompactionEnabled: true }
  if (ultracode) settings.ultracode = true
  if (configuration.advisor.mode === 'automatic' && configuration.advisor.model) {
    settings.advisorModel = configuration.advisor.model
  }
  if (configuration.speed === 'fast') {
    settings.fastMode = true
    // Fast is a per-conversation choice. Without this, another session inheriting the setting would
    // silently bill at the Fast multiplier.
    settings.fastModePerSessionOptIn = true
  }
  // `configuration.refusalFallback` is deliberately NOT mapped to any SDK option here. The pinned
  // SDK's `Options.fallbackModel` documents itself as the OPERATIONAL path ("if the primary model is
  // overloaded or unavailable") — it is not the classifier-refusal mechanism, which routes through a
  // per-category refusal fallback map plus a `refusal_fallback_prompt` consumer dialog. Mapping the
  // safety preference onto the overload option would quietly change behavior on outages while
  // claiming to be a safety control. The wiring lands in plan Phase 1C, on evidence.

  // Demote oversized bundled skills only on a lane that genuinely cannot seat them. A 1M lane holds
  // the reference comfortably, and taking it away there would remove a working capability and add a
  // compensating system-prompt instruction for a problem that lane does not have.
  const resolvedModel = resolveClaudeModel(requested, { authMode, disable1M })
  // Claude's live catalog deliberately exposes stable wire aliases such as `fable`, while its
  // `resolvedModel` field names the concrete generation that determines the context window. Keep
  // the alias on the provider wire, but size the turn and key measurements by that catalog-backed
  // identity. Without this split Fable 5.1 is sent correctly yet treated as an unknown 200K model.
  const contextModel = catalogResolvedModel === null
      || catalogResolvedModel === undefined
      || catalogResolvedModel === ''
    ? resolvedModel
    : parseModel(catalogResolvedModel, 'catalogResolvedModel')
  // Prefer what this route was measured to serve. The static answer is a derivation from id and
  // route, and it cannot know about a model a managed profile introduced after this build shipped.
  let measuredWindow = null
  if (typeof lookupMeasuredWindow === 'function') {
    // A memory lookup is a cache read and is never allowed to fail a turn.
    try { measuredWindow = lookupMeasuredWindow(contextModel) } catch { measuredWindow = null }
  }
  const context = claudeContextWindowDecision(contextModel, { authMode, measuredWindow })
  if (!allowOversizedSkills && context.window < OVERSIZED_SKILL_MINIMUM_WINDOW) {
    settings.skillOverrides = {}
    for (const name of OVERSIZED_BUNDLED_SKILLS) {
      settings.skillOverrides[name] = 'user-invocable-only'
    }
  }

  return {
    model: resolvedModel,
    contextModel,
    effort: resolvedEffort,
    settings,
    contextWindow: context.window,
    contextWindowSource: context.source,
  }
}
