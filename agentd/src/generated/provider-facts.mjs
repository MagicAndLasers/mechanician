// GENERATED FILE — DO NOT EDIT.
//
// Source:    shared/provider-facts.json
// Regenerate: node scripts/generate-provider-facts.mjs
//
// Edit the source and regenerate. scripts/check.sh fails when this file does not match the
// source, so the daemon and the app cannot disagree about a provider fact without the build
// saying so. That is the whole point: these lists used to be kept identical by hand, and one
// pair drifted.

// Models upgraded from their bare id to the `[1m]` variant on a first-party route.
// Never applied on a third-party route, so a bare id there stays bare and its window stays
// 200K.
//
// The reason is entitlement, NOT availability. An earlier version of this note claimed the
// suffixed id 'names a configuration those routes do not serve'. That is false, and was
// measured false: on 2026-08-13 `claude-opus-4-8[1m]`, named explicitly by a managed tenant
// profile on a Vertex route, served a confirmed 1,000,000-token window. That deployment had
// no access to a 1M Opus window until the suffixed entry was added, so the variant is real
// and reachable on Vertex.
//
// We still never synthesize the suffix on a third-party route, because a 1M variant is enabled
// per project there and we cannot verify another project's entitlement from here. Synthesizing
// it would name a model that a DIFFERENT Vertex or Bedrock project may not serve, turning a
// working bare selection into a failing one. A tenant that has the variant declares it
// explicitly in its profile, which is exactly what the measurement above came from, and
// `effectiveClaudeContextWindow` then honors the named variant on any route.
export const millionTokenSuffixUpgrades = new Set([
  "claude-opus-4-8",
])

// Models that ship a 1M window with no variant suffix, ON A FIRST-PARTY ROUTE.
// Third-party routes additionally require membership in `thirdPartyMillionTokenModels`.
//
// Bare ids only. A route may still serve an explicitly named `[1m]` variant of a model that
// is absent from both lists, which is a separate question this list does not answer.
export const nativeMillionTokenModels = new Set([
  "claude-fable-5",
  "claude-fable-5-1",
  "claude-mythos-5",
  "claude-mythos-5-1",
  "claude-opus-5",
  "claude-sonnet-5",
])

// Routes where the Opus 5 preview surfaces (Advisor, Fast mode, configurable refusal
// fallback) are not documented as available, so they fail closed no matter what a client asks
// for or which dev gate is enabled.
//
// This is the fact that drifted. The daemon listed only `vertex` while the app withheld the
// same surfaces on Vertex and Bedrock, so a request naming a preview surface on Bedrock or
// Foundry passed the daemon's last gate. Managed clouds lag first-party feature availability;
// each stays withheld until verified against that backend, which is the app's stated rule and
// is now the only rule.
export const routesWithoutPreviewSurfaces = new Set([
  "vertex",
  "bedrock",
  "foundry",
])

// The subset whose BARE id ALSO gets 1M on Vertex, Bedrock or Foundry.
//
// Verified against the pinned engine's model registry: a 1M window for a bare id on a
// third-party route requires `context.native_1m_3p[route] === true`, and `claude-sonnet-5` is
// the only model in the whole registry that declares it. Opus 5, both Fable 5 generations,
// and both Mythos 5 generations are `native_1m` on first-party only, so a third-party route
// serves their bare id at 200K.
//
// Treating them as 1M there is what re-opens issue 47: the oversized-skill demotion never
// fires and the `claude-api` payload lands in a window that cannot hold it.
//
// SCOPE. This list governs bare ids. It is NOT a claim about what a route serves for an
// explicitly named `[1m]` variant, and it must not be read as one. Reading it that way is a
// mistake that has already been made: it produced a recommendation to delete a tenant's
// working 1M model entry. The registry describes automatic upgrade eligibility, not
// per-project entitlement.
export const thirdPartyMillionTokenModels = new Set([
  "claude-sonnet-5",
])

// Qualifiers third-party catalogs prepend to a model id (Bedrock inference profiles such as
// `global.anthropic.claude-sonnet-5`, Vertex publisher paths). Stripped longest-first so a
// route-shaped id compares against the same canonical name as a bare one.
export const thirdPartyModelIDPrefixes = Object.freeze([
  "publishers/anthropic/models/",
  "global.anthropic.",
  "us.anthropic.",
  "eu.anthropic.",
  "apac.anthropic.",
  "anthropic.",
])

// Routes served by someone else's cloud rather than Anthropic directly.
// Model naming and window size both differ here: the engine gates a BARE id's 1M window
// behind a per-model `native_1m_3p` flag, and third-party catalogs qualify the model id.
// That flag says nothing about an EXPLICITLY named `[1m]` variant; see
// `millionTokenSuffixUpgrades` for the measurement that separates the two.
export const thirdPartyRoutes = new Set([
  "vertex",
  "bedrock",
  "foundry",
])
