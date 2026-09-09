// Claude Opus 5 adoption, plan Phase 0 (O5-001/O5-002/O5-005): the option contract.
//
// The load-bearing test in this file is the FIRST one. Everything else in the Opus 5 sequence is
// layered on the promise that a turn carrying no Claude preferences produces exactly the options the
// pre-refactor daemon produced. That is asserted against a literal snapshot, not against the
// implementation, so a future refactor cannot quietly move the baseline.
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'

import {
  CLAUDE_ADVISOR_MODEL,
  CLAUDE_DEFAULT_MODEL,
  CLAUDE_EXPERIMENTAL_FEATURES,
  CLAUDE_TURN_OPTION_LIMITS,
  ClaudeTurnOptionError,
  DEFAULT_CLAUDE_TURN_CONFIGURATION,
  OVERSIZED_BUNDLED_SKILLS,
  buildClaudeQueryOptions,
  claudeContextWindowDecision,
  effectiveClaudeContextWindow,
  claudeExperimentalFeatures,
  parseClaudeTurnConfiguration,
  resolveClaudeModel,
} from '../src/claude-turn-options.mjs'

const ALL_FEATURES = new Set(CLAUDE_EXPERIMENTAL_FEATURES)

function parse(raw, overrides = {}) {
  return parseClaudeTurnConfiguration(raw, { provider: 'anthropic', ...overrides })
}

function rejects(fn, expected) {
  assert.throws(fn, (error) => {
    assert.ok(error instanceof ClaudeTurnOptionError,
              `expected ClaudeTurnOptionError, got ${error?.name}: ${error?.message}`)
    if (expected) assert.match(error.message, expected)
    return true
  })
}

// ── the no-op baseline ──

test('a turn with no Claude block produces the pre-refactor SDK options exactly', () => {
  // Snapshot of what agentd built inline before `claude-turn-options.mjs` existed:
  //   model: resolveModel(model || DEFAULT_MODEL)
  //   effort: absent unless supplied
  //   settings: { enableWorkflows: true, precomputeCompactionEnabled: true }
  // A 1M lane is untouched: it seats the oversized reference comfortably, so no demotion appears
  // and this really is the pre-refactor object.
  const built = buildClaudeQueryOptions({ model: 'claude-opus-4-8' })
  const { contextModel, contextWindow, contextWindowSource, ...sdkFacing } = built
  assert.deepEqual(
    sdkFacing,
    {
      model: 'claude-opus-4-8[1m]',
      effort: null,
      settings: { enableWorkflows: true, precomputeCompactionEnabled: true },
    })
  // The context fields are diagnostics and local identity, not SDK options. agentd reads `model`,
  // `effort` and `settings` off this object individually and never spreads it into the query.
  assert.deepEqual(
    Object.keys(built).sort(),
    ['contextModel', 'contextWindow', 'contextWindowSource', 'effort', 'model', 'settings'])
  assert.equal(contextModel, 'claude-opus-4-8[1m]')
  assert.equal(contextWindow, 1_000_000)
  assert.equal(contextWindowSource, 'assumed')

  // Key ORDER matters for any serialized comparison of the settings object.
  assert.deepEqual(
    Object.keys(buildClaudeQueryOptions({ model: 'claude-opus-5' }).settings),
    ['enableWorkflows', 'precomputeCompactionEnabled'])
})

test('the effective window follows the RESOLVED model, not the requested one', () => {
  // The fact issue 47 turned on. Opus 4.8 reaches 1M only through the `[1m]` variant, and that
  // variant is deliberately not applied on Vertex, so the same requested model is a 1M lane on a
  // subscription and a 200K lane on Vertex.
  assert.equal(effectiveClaudeContextWindow('claude-opus-4-8[1m]'), 1_000_000)
  assert.equal(effectiveClaudeContextWindow('claude-opus-4-8'), 200_000)
  assert.equal(effectiveClaudeContextWindow('claude-opus-5'), 1_000_000)
  assert.equal(effectiveClaudeContextWindow('claude-fable-5-1'), 1_000_000)
  assert.equal(effectiveClaudeContextWindow('claude-sonnet-4-5'), 200_000)
  // Anything unrecognized is treated as small on purpose: guessing high is what puts an unfittable
  // payload back inside the window.
  assert.equal(effectiveClaudeContextWindow('some-future-model'), 200_000)
  assert.equal(effectiveClaudeContextWindow(''), 200_000)
  assert.equal(effectiveClaudeContextWindow(undefined), 200_000)
})

test('a third-party route gets 1M only for the model that declares it', () => {
  // Verified against the pinned engine's model registry: a 1M window on Vertex, Bedrock or Foundry
  // requires `context.native_1m_3p[route] === true`, and `claude-sonnet-5` is the ONLY model in the
  // registry that declares it. Opus 5 and both Fable/Mythos generations are first-party-only.
  // A route-blind answer here reported 1M for Opus 5 on Vertex, which kept the oversized
  // `claude-api` skill enabled on a 200K lane — issue 47, re-opened on the managed enterprise route.
  for (const authMode of ['vertex', 'bedrock', 'foundry']) {
    assert.equal(effectiveClaudeContextWindow('claude-opus-5', { authMode }), 200_000)
    assert.equal(effectiveClaudeContextWindow('claude-fable-5', { authMode }), 200_000)
    assert.equal(effectiveClaudeContextWindow('claude-fable-5-1', { authMode }), 200_000)
    assert.equal(effectiveClaudeContextWindow('claude-mythos-5', { authMode }), 200_000)
    assert.equal(effectiveClaudeContextWindow('claude-mythos-5-1', { authMode }), 200_000)
    assert.equal(effectiveClaudeContextWindow('claude-sonnet-5', { authMode }), 1_000_000)
  }
  // First-party routes keep every native-1M generation at its advertised window.
  for (const authMode of ['apikey', 'subscription']) {
    for (const model of [
      'claude-opus-5',
      'claude-fable-5',
      'claude-fable-5-1',
      'claude-mythos-5',
      'claude-mythos-5-1',
      'claude-sonnet-5',
    ]) {
      assert.equal(effectiveClaudeContextWindow(model, { authMode }), 1_000_000)
    }
  }
  // A route-qualified id has to compare as the same canonical model, or a Bedrock inference
  // profile would silently answer 200K for a model that genuinely has the window.
  assert.equal(
    effectiveClaudeContextWindow('global.anthropic.claude-opus-5', { authMode: 'bedrock' }),
    200_000)
  assert.equal(
    effectiveClaudeContextWindow('us.anthropic.claude-sonnet-5', { authMode: 'bedrock' }),
    1_000_000)
  assert.equal(
    effectiveClaudeContextWindow(
      'publishers/anthropic/models/claude-sonnet-5', { authMode: 'vertex' }),
    1_000_000)
})

test('a catalog-resolved alias keeps its wire value but uses the concrete model window', () => {
  const firstPartyLookups = []
  const firstParty = buildClaudeQueryOptions({
    model: 'fable',
    catalogResolvedModel: 'claude-fable-5-1',
    authMode: 'subscription',
    lookupMeasuredWindow: (model) => { firstPartyLookups.push(model); return null },
  })
  assert.equal(firstParty.model, 'fable')
  assert.equal(firstParty.contextModel, 'claude-fable-5-1')
  assert.equal(firstParty.contextWindow, 1_000_000)
  assert.equal(firstParty.settings.skillOverrides, undefined)
  assert.deepEqual(firstPartyLookups, ['claude-fable-5-1'])

  const vertex = buildClaudeQueryOptions({
    model: 'fable',
    catalogResolvedModel: 'claude-fable-5-1',
    authMode: 'vertex',
  })
  assert.equal(vertex.model, 'fable')
  assert.equal(vertex.contextModel, 'claude-fable-5-1')
  assert.equal(vertex.contextWindow, 200_000)
  for (const name of OVERSIZED_BUNDLED_SKILLS) {
    assert.equal(vertex.settings.skillOverrides?.[name], 'user-invocable-only')
  }
})

test('an explicitly named [1m] variant keeps its window on a third-party route', () => {
  // MEASURED, not inferred. On 2026-08-13 a managed tenant profile declared
  // `claude-opus-4-8[1m]` on a Vertex route and the provider served a confirmed 1,000,000-token
  // window. That deployment had no 1M Opus window at all until the suffixed entry was added, so the
  // variant is real and reachable on Vertex.
  //
  // This test exists to stop a specific mistake, which has already been made once: reading
  // `thirdPartyMillionTokenModels` (which governs BARE ids) as a statement about named variants,
  // concluding the tenant's entry was wrong, and "fixing" the window down to 200K. That would cut a
  // real 1M window by 5x and re-demote skills the lane can actually seat.
  for (const authMode of ['vertex', 'bedrock', 'foundry']) {
    assert.equal(effectiveClaudeContextWindow('claude-opus-4-8[1m]', { authMode }), 1_000_000)
    assert.equal(effectiveClaudeContextWindow('claude-opus-4-6[1m]', { authMode }), 1_000_000)
    // The bare id is a different selection and still answers 200K, because we never synthesize the
    // suffix on these routes. Both entries coexist in the tenant profile for exactly this reason.
    assert.equal(effectiveClaudeContextWindow('claude-opus-4-8', { authMode }), 200_000)
  }
  // A named variant reaches the window function unchanged, so a profile-declared id is honored
  // rather than rewritten on its way to the provider.
  for (const authMode of ['vertex', 'bedrock', 'foundry']) {
    assert.equal(
      resolveClaudeModel('claude-opus-4-8[1m]', { authMode }), 'claude-opus-4-8[1m]')
  }
  // A 1M lane seats the oversized bundled skills, so a tenant that declared the variant keeps the
  // capability instead of having it budgeted away.
  assert.equal(
    buildClaudeQueryOptions({ model: 'claude-opus-4-8[1m]', authMode: 'vertex' })
      .settings.skillOverrides,
    undefined)
})

test('a measured window overrides the assumption in both directions', () => {
  // The assumption is a derivation from id and route. It cannot know what a managed profile added
  // after this build shipped, and it was never checked against what the provider actually served.
  // Once a completed turn reports a real denominator, that number is the better answer.

  // No measurement: unchanged behavior, and the source says so rather than implying certainty.
  assert.deepEqual(
    claudeContextWindowDecision('claude-opus-5', { authMode: 'vertex' }),
    { window: 200_000, source: 'assumed' })

  // DOWN. We believed 1M, the provider served 200K. Believing the measurement is what makes the
  // oversized-skill demotion fire on a lane that genuinely cannot seat the payload.
  assert.deepEqual(
    claudeContextWindowDecision('claude-opus-4-8[1m]',
                                { authMode: 'vertex', measuredWindow: 200_000 }),
    { window: 200_000, source: 'measured' })
  const demoted = buildClaudeQueryOptions({
    model: 'claude-opus-4-8[1m]',
    authMode: 'vertex',
    lookupMeasuredWindow: () => 200_000,
  })
  for (const name of OVERSIZED_BUNDLED_SKILLS) {
    assert.equal(demoted.settings.skillOverrides?.[name], 'user-invocable-only')
  }
  assert.equal(demoted.contextWindowSource, 'measured')

  // UP. We assumed 200K, the route really serves 1M. This is the managed-tenant direction, and
  // refusing it would take away a capability the lane has.
  assert.deepEqual(
    claudeContextWindowDecision('claude-opus-5', { authMode: 'vertex', measuredWindow: 1_000_000 }),
    { window: 1_000_000, source: 'measured' })
  const kept = buildClaudeQueryOptions({
    model: 'claude-opus-5',
    authMode: 'vertex',
    lookupMeasuredWindow: () => 1_000_000,
  })
  assert.equal(kept.settings.skillOverrides, undefined)
  assert.equal(kept.contextWindow, 1_000_000)

  // The lookup receives the RESOLVED id, because that is what the provider reported usage for.
  // Keying the memory on the requested id would miss on every first-party Opus 4.8 turn.
  const seen = []
  buildClaudeQueryOptions({
    model: 'claude-opus-4-8',
    lookupMeasuredWindow: (id) => { seen.push(id); return null },
  })
  assert.deepEqual(seen, ['claude-opus-4-8[1m]'])

  // A cache read must never fail a turn, so a throwing or nonsense lookup falls back silently.
  for (const lookup of [() => { throw new Error('unreadable') }, () => 0, () => -1,
                        () => 'huge', () => null, () => 1.5]) {
    const built = buildClaudeQueryOptions({
      model: 'claude-opus-5', authMode: 'vertex', lookupMeasuredWindow: lookup,
    })
    assert.equal(built.contextWindow, 200_000)
    assert.equal(built.contextWindowSource, 'assumed')
  }
})

test('the oversized skill is demoted for Opus 5 on a third-party route', () => {
  // The managed-Vertex shape: a managed profile defaulting to Opus 5. While the window answer ignored the
  // route this lane looked like 1M, so the demotion never fired and the deadlock was reachable.
  for (const authMode of ['vertex', 'bedrock']) {
    const built = buildClaudeQueryOptions({ model: 'claude-opus-5', authMode })
    assert.equal(built.model, 'claude-opus-5')
    for (const name of OVERSIZED_BUNDLED_SKILLS) {
      assert.equal(built.settings.skillOverrides?.[name], 'user-invocable-only')
    }
  }
  // Sonnet 5 genuinely has the window there, so nothing is taken away.
  assert.equal(
    buildClaudeQueryOptions({ model: 'claude-sonnet-5', authMode: 'vertex' })
      .settings.skillOverrides,
    undefined)
})

test('oversized bundled skills are demoted only on a lane that cannot seat them', () => {
  // 200K lanes: demoted. `user-invocable-only` is the whole product promise, because the model
  // cannot inline the reference while the person can still type /claude-api and get the full text.
  // `off` would delete the capability instead of budgeting it, so it must never appear.
  const small = [
    buildClaudeQueryOptions({ model: 'claude-sonnet-4-5' }),
    // The managed-Vertex case: we never SYNTHESIZE the [1m] variant on Vertex, so a bare Opus
    // request runs at 200K there. A profile that declares the variant outright is a different
    // selection and keeps its 1M window; see the named-variant test above.
    buildClaudeQueryOptions({ model: 'claude-opus-4-8', authMode: 'vertex' }),
    buildClaudeQueryOptions({ model: 'claude-opus-4-8', disable1M: true }),
    // Opus 5 is `native_1m` on a FIRST-PARTY route only. The engine registry gives it no
    // `native_1m_3p`, so Vertex and Bedrock serve it at 200K and it needs the demotion too. This
    // case sat in the 1M list below until the route became part of the window answer.
    buildClaudeQueryOptions({ model: 'claude-opus-5', authMode: 'vertex' }),
    buildClaudeQueryOptions({ model: 'claude-opus-5', authMode: 'bedrock' }),
  ]
  for (const built of small) {
    for (const name of OVERSIZED_BUNDLED_SKILLS) {
      assert.equal(built.settings.skillOverrides[name], 'user-invocable-only')
      assert.notEqual(built.settings.skillOverrides[name], 'off')
    }
  }

  // 1M lanes: untouched. Removing a capability that fits, then adding a system-prompt instruction
  // to compensate, would be pure cost on these lanes.
  const large = [
    buildClaudeQueryOptions({ model: 'claude-opus-4-8' }),
    buildClaudeQueryOptions({ model: 'claude-opus-5' }),
    // Sonnet 5 is the one model that declares `native_1m_3p`, so it keeps the window, and the
    // reference, on a managed route.
    buildClaudeQueryOptions({ model: 'claude-sonnet-5', authMode: 'vertex' }),
  ]
  for (const built of large) {
    assert.equal('skillOverrides' in built.settings, false)
  }
})

test('allowOversizedSkills restores the previous settings object byte for byte', () => {
  // The escape hatch exists to reproduce the original overflow, so it has to be total: anything
  // less than byte-identical means the reproduction is not measuring the old behaviour. Checked on
  // a 200K lane, since that is the only place the demotion would otherwise appear.
  const relaxed = buildClaudeQueryOptions({ model: 'claude-sonnet-4-5', allowOversizedSkills: true })
  assert.equal(
    JSON.stringify(relaxed.settings),
    JSON.stringify({ enableWorkflows: true, precomputeCompactionEnabled: true }))
  assert.equal('skillOverrides' in relaxed.settings, false)
})

test('an absent block and an explicitly all-default block are indistinguishable', () => {
  // An omitted block short-circuits to the shared default (identity); a present-but-empty block
  // walks the full validator and must still land on an equal snapshot.
  assert.equal(parse(undefined), DEFAULT_CLAUDE_TURN_CONFIGURATION)
  assert.equal(parse(null), DEFAULT_CLAUDE_TURN_CONFIGURATION)
  assert.deepEqual(parse({}), DEFAULT_CLAUDE_TURN_CONFIGURATION)

  const explicit = parse({
    advisor: { mode: 'off' }, speed: 'standard', refusalFallback: { mode: 'off' }, thinking: 'adaptive',
  })
  assert.deepEqual(explicit, DEFAULT_CLAUDE_TURN_CONFIGURATION)
  assert.deepEqual(
    buildClaudeQueryOptions({ model: 'claude-opus-5', configuration: explicit }),
    buildClaudeQueryOptions({ model: 'claude-opus-5' }))
})

test('the parsed snapshot is frozen, so an accepted turn cannot be mutated mid-flight', () => {
  const configuration = parse({ speed: 'fast' }, { experimental: ALL_FEATURES })
  assert.throws(() => { configuration.speed = 'standard' }, TypeError)
  assert.throws(() => { configuration.advisor.mode = 'automatic' }, TypeError)
})

// ── model resolution (the Opus 5 pass-through contract) ──

test('Opus 4.8 keeps its legacy [1m] variant and Opus 5 passes through natively', () => {
  assert.equal(resolveClaudeModel('claude-opus-4-8'), 'claude-opus-4-8[1m]')
  // Opus 5 is natively 1M. Suffixing it would name a model the provider does not publish.
  assert.equal(resolveClaudeModel('claude-opus-5'), 'claude-opus-5')
  assert.equal(resolveClaudeModel('claude-sonnet-5'), 'claude-sonnet-5')
})

test('third-party routes and the opt-out all pass every model through unchanged', () => {
  assert.equal(resolveClaudeModel('claude-opus-4-8', { authMode: 'vertex' }), 'claude-opus-4-8')
  // Bedrock and Foundry gate 1M the same way Vertex does: the registry gives `claude-opus-4-8`
  // `native_1m` but no `native_1m_3p`, so a `[1m]` id there names a lane the route does not serve.
  assert.equal(resolveClaudeModel('claude-opus-4-8', { authMode: 'bedrock' }), 'claude-opus-4-8')
  assert.equal(resolveClaudeModel('claude-opus-4-8', { authMode: 'foundry' }), 'claude-opus-4-8')
  assert.equal(resolveClaudeModel('claude-opus-4-8', { disable1M: true }), 'claude-opus-4-8')
  assert.equal(
    resolveClaudeModel('claude-opus-4-5@20250101', { authMode: 'vertex' }),
    'claude-opus-4-5@20250101')
})

test('an absent model falls back to the one declared Claude default', () => {
  // Phase 2 flips this constant in a single isolated commit; nothing else should encode it.
  assert.equal(CLAUDE_DEFAULT_MODEL, 'claude-opus-4-8')
  assert.equal(buildClaudeQueryOptions({}).model, 'claude-opus-4-8[1m]')
  assert.equal(buildClaudeQueryOptions({ model: '' }).model, 'claude-opus-4-8[1m]')
  assert.equal(buildClaudeQueryOptions({ model: null }).model, 'claude-opus-4-8[1m]')
})

test('Vertex publisher ids and legacy context variants survive validation', () => {
  for (const model of [
    'claude-opus-5',
    'claude-opus-4-8[1m]',
    'claude-opus-4-5@20250101',
    'publishers/anthropic/models/claude-opus-4-5',
  ]) {
    assert.equal(
      buildClaudeQueryOptions({ model, authMode: 'vertex' }).model, model, `${model} must pass through`)
  }
})

test('an out-of-bounds or malformed model is refused before a provider spawns', () => {
  rejects(() => buildClaudeQueryOptions({ model: 'x'.repeat(CLAUDE_TURN_OPTION_LIMITS.modelCharacters + 1) }),
          /at most 256 characters/)
  rejects(() => buildClaudeQueryOptions({ model: 'claude opus 5' }), /unsupported characters/)
  rejects(() => buildClaudeQueryOptions({ model: 'claude\nopus' }), /unsupported characters/)
  rejects(() => buildClaudeQueryOptions({ model: 42 }), /must be a string/)
  rejects(() => buildClaudeQueryOptions({
    model: 'fable', catalogResolvedModel: 'claude fable 5.1',
  }), /unsupported characters/)
})

// ── effort and ultracode ──

test('effort is omitted when absent and pinned to xhigh by ultracode', () => {
  assert.equal(buildClaudeQueryOptions({ model: 'claude-opus-5' }).effort, null)
  assert.equal(buildClaudeQueryOptions({ model: 'claude-opus-5', effort: '  ' }).effort, null)
  assert.equal(buildClaudeQueryOptions({ model: 'claude-opus-5', effort: ' medium ' }).effort, 'medium')

  const ultra = buildClaudeQueryOptions({ model: 'claude-opus-5', effort: 'low', ultracode: true })
  assert.equal(ultra.effort, 'xhigh')
  assert.equal(ultra.settings.ultracode, true)
  assert.deepEqual(
    Object.keys(ultra.settings), ['enableWorkflows', 'precomputeCompactionEnabled', 'ultracode'])
})

test('effort accepts provider-reported levels this build has never heard of', () => {
  // Effort levels come from supportedModels(); a fixed enum here would break on the next one shipped.
  assert.equal(buildClaudeQueryOptions({ model: 'claude-opus-5', effort: 'ludicrous' }).effort, 'ludicrous')
  rejects(() => buildClaudeQueryOptions({ model: 'claude-opus-5', effort: 'Medium; rm -rf' }),
          /not a supported value/)
  rejects(() => buildClaudeQueryOptions({ model: 'claude-opus-5', effort: 'x'.repeat(33) }),
          /not a supported value/)
})

// ── the thinking/effort invariant (O5-005) ──

test('thinking cannot be disabled at xhigh or max effort', () => {
  const disabled = parse({ thinking: 'disabled' })
  assert.equal(disabled.thinking, 'disabled')

  for (const effort of ['xhigh', 'max']) {
    rejects(() => buildClaudeQueryOptions({ model: 'claude-opus-5', effort, configuration: disabled }),
            new RegExp(`Thinking cannot be disabled at ${effort} effort`))
  }
  // Ultracode pins xhigh implicitly, so it must be caught even with a lighter requested effort.
  rejects(() => buildClaudeQueryOptions({
    model: 'claude-opus-5', effort: 'medium', ultracode: true, configuration: disabled,
  }), /Thinking cannot be disabled at xhigh effort/)
})

test('current adaptive-thinking turns pass at every effort', () => {
  for (const effort of ['low', 'medium', 'high', 'xhigh', 'max']) {
    const built = buildClaudeQueryOptions({ model: 'claude-opus-5', effort })
    assert.equal(built.effort, effort)
  }
  // Disabled thinking below the threshold remains legal — the invariant is about the pairing.
  assert.equal(
    buildClaudeQueryOptions({
      model: 'claude-opus-5', effort: 'medium', configuration: parse({ thinking: 'disabled' }),
    }).effort,
    'medium')
})

// ── lane isolation ──

test('a Claude block on a Codex or OpenAI lane is refused, never silently dropped', () => {
  for (const provider of ['codex', 'openai']) {
    rejects(
      () => parseClaudeTurnConfiguration({ speed: 'fast' }, { provider, experimental: ALL_FEATURES }),
      new RegExp(`not available on the ${provider} lane`))
    // An empty object is the app sending nothing meaningful; that must stay legal.
    assert.equal(
      parseClaudeTurnConfiguration({}, { provider }), DEFAULT_CLAUDE_TURN_CONFIGURATION)
    assert.equal(
      parseClaudeTurnConfiguration(undefined, { provider }), DEFAULT_CLAUDE_TURN_CONFIGURATION)
  }
})

test('unknown keys are rejected so a typo cannot pass as an accepted preference', () => {
  rejects(() => parse({ advisorModel: 'claude-opus-5' }), /does not support “advisorModel”/)
  rejects(() => parse({ advisor: { mode: 'automatic', maxUses: 3 } }, { experimental: ALL_FEATURES }),
          /does not support “maxUses”/)
  rejects(() => parse({ refusalFallback: { mode: 'off', category: 'cyber' } }),
          /does not support “category”/)
  rejects(() => parse([]), /must be an object/)
  rejects(() => parse({ advisor: 'automatic' }), /claude.advisor must be an object/)
})

// ── the experimental gate ──

test('the dev gate parses only known features and defaults to everything off', () => {
  assert.deepEqual([...claudeExperimentalFeatures({})], [])
  assert.deepEqual([...claudeExperimentalFeatures({ MECHANICIAN_ENABLE_CLAUDE_EXPERIMENTS: '' })], [])
  assert.deepEqual(
    [...claudeExperimentalFeatures({ MECHANICIAN_ENABLE_CLAUDE_EXPERIMENTS: ' advisor , fast ' })],
    ['advisor', 'fast'])
  assert.deepEqual(
    [...claudeExperimentalFeatures({ MECHANICIAN_ENABLE_CLAUDE_EXPERIMENTS: 'advisor,managedAgents' })],
    ['advisor'])
})

test('an ungated preference fails closed with a message naming the feature', () => {
  rejects(() => parse({ advisor: { mode: 'automatic' } }), /The Opus 5 advisor is not available/)
  rejects(() => parse({ speed: 'fast' }), /Fast mode is not available/)
  rejects(() => parse({ refusalFallback: { mode: 'providerDefault' } }),
          /Automatic safety fallback is not available/)

  // One feature enabled must not unlock the others.
  const onlyFast = new Set(['fast'])
  assert.equal(parse({ speed: 'fast' }, { experimental: onlyFast }).speed, 'fast')
  rejects(() => parse({ advisor: { mode: 'automatic' } }, { experimental: onlyFast }),
          /The Opus 5 advisor is not available/)
})

test('an all-default block needs no gate at all', () => {
  // A conversation that persisted its defaults must send successfully in a release build.
  assert.deepEqual(
    parse({ advisor: { mode: 'off' }, speed: 'standard', refusalFallback: { mode: 'off' } }),
    DEFAULT_CLAUDE_TURN_CONFIGURATION)
})

// ── Advisor mapping ──

test('an opted-in advisor maps to settings.advisorModel and defaults to Opus 5', () => {
  const configuration = parse({ advisor: { mode: 'automatic' } }, { experimental: ALL_FEATURES })
  assert.deepEqual(configuration.advisor, { mode: 'automatic', model: CLAUDE_ADVISOR_MODEL })

  const built = buildClaudeQueryOptions({ model: 'claude-sonnet-5', effort: 'medium', configuration })
  assert.equal(built.settings.advisorModel, 'claude-opus-5')
  assert.equal(built.settings.fastMode, undefined)
})

test('an advisor left off contributes no setting, and a model without a mode is refused', () => {
  assert.equal(
    buildClaudeQueryOptions({ model: 'claude-sonnet-5', configuration: parse({ advisor: { mode: 'off' } }) })
      .settings.advisorModel,
    undefined)
  rejects(() => parse({ advisor: { mode: 'off', model: 'claude-opus-5' } }, { experimental: ALL_FEATURES }),
          /requires an active advisor mode/)
  rejects(() => parse({ advisor: { mode: 'sometimes' } }, { experimental: ALL_FEATURES }),
          /must be one of: off, automatic/)
})

// ── Fast mode mapping ──

test('Fast maps to both SDK settings so it cannot leak into another session', () => {
  const configuration = parse({ speed: 'fast' }, { experimental: ALL_FEATURES })
  const built = buildClaudeQueryOptions({ model: 'claude-opus-5', configuration })
  assert.equal(built.settings.fastMode, true)
  assert.equal(built.settings.fastModePerSessionOptIn, true)
})

test('Standard speed is byte-equivalent to the baseline settings', () => {
  const standard = buildClaudeQueryOptions({
    model: 'claude-opus-5', configuration: parse({ speed: 'standard' }),
  })
  assert.deepEqual(standard, buildClaudeQueryOptions({ model: 'claude-opus-5' }))
  assert.equal(JSON.stringify(standard.settings),
               JSON.stringify({ enableWorkflows: true, precomputeCompactionEnabled: true }))
})

// ── refusal fallback stays unmapped until its spike lands ──

test('a refusal-fallback preference is carried but maps to NO SDK option yet', () => {
  // Deliberate: the pinned SDK's Options.fallbackModel is the OPERATIONAL (overload/unavailable)
  // path, not the classifier-refusal mechanism. Mapping the safety preference onto it would change
  // outage behavior while claiming to be a safety control. Plan Phase 1C wires this on evidence.
  for (const raw of [{ mode: 'providerDefault' }, { mode: 'model', model: 'claude-opus-4-8' }]) {
    const configuration = parse({ refusalFallback: raw }, { experimental: ALL_FEATURES })
    assert.equal(configuration.refusalFallback.mode, raw.mode)
    const built = buildClaudeQueryOptions({ model: 'claude-opus-5', configuration })
    assert.deepEqual(built.settings, { enableWorkflows: true, precomputeCompactionEnabled: true })
    assert.equal('fallbackModel' in built, false)
  }
})

test('the refusal-fallback model is required by “model” mode and rejected by the others', () => {
  rejects(() => parse({ refusalFallback: { mode: 'model' } }, { experimental: ALL_FEATURES }),
          /must be a string/)
  rejects(
    () => parse({ refusalFallback: { mode: 'providerDefault', model: 'claude-opus-4-8' } },
                { experimental: ALL_FEATURES }),
    /only valid with mode “model”/)
  rejects(() => parse({ refusalFallback: { mode: 'off', model: 'claude-opus-4-8' } },
                      { experimental: ALL_FEATURES }),
          /requires an active fallback mode/)
})

// ── Third-party route exclusion ──
//
// These looped over `vertex` alone, and so did the Set they were testing, while the app withheld the
// same surfaces on Vertex AND Bedrock. The daemon's gate was therefore open on Bedrock and Foundry
// and no test noticed, because no test asked. Both now cover every third-party route.

test('no third-party route accepts a preview surface, whatever the dev gate says', () => {
  for (const authMode of ['vertex', 'bedrock', 'foundry']) {
    const route = { authMode, experimental: ALL_FEATURES }
    rejects(() => parse({ advisor: { mode: 'automatic' } }, route),
            /advisor is not available on this Claude route/)
    rejects(() => parse({ speed: 'fast' }, route),
            /Fast mode is not available on this Claude route/)
    rejects(() => parse({ refusalFallback: { mode: 'providerDefault' } }, route),
            /safety fallback is not available on this Claude route/)

    // Defaults and adaptive thinking remain fine — the route is not crippled, just honest.
    assert.deepEqual(parse({ advisor: { mode: 'off' }, speed: 'standard' }, route),
                     DEFAULT_CLAUDE_TURN_CONFIGURATION, authMode)
  }
})

test('the option builder is the last gate: a hand-built preview config cannot reach any of them', () => {
  // Belt and suspenders for a future caller that assembles a configuration without parsing one.
  const advisor = { ...DEFAULT_CLAUDE_TURN_CONFIGURATION, advisor: { mode: 'automatic', model: 'claude-opus-5' } }
  const fast = { ...DEFAULT_CLAUDE_TURN_CONFIGURATION, speed: 'fast' }
  for (const authMode of ['vertex', 'bedrock', 'foundry']) {
    rejects(() => buildClaudeQueryOptions({ model: 'claude-opus-4-5@1', authMode, configuration: advisor }),
            /advisor is not available on this Claude route/)
    rejects(() => buildClaudeQueryOptions({ model: 'claude-opus-4-5@1', authMode, configuration: fast }),
            /Fast mode is not available on this Claude route/)
  }
})

test('first-party routes still get the preview surfaces', () => {
  // The counterpart, so a future over-correction that withholds everything everywhere is caught.
  for (const authMode of ['subscription', 'apikey']) {
    assert.equal(
      parse({ speed: 'fast' }, { authMode, experimental: ALL_FEATURES }).speed, 'fast', authMode)
  }
})

// ── the daemon actually uses the module ──

test('agentd routes model and settings resolution through this module, not a second copy', () => {
  // Guards against the refactor being half-applied: a stray inline `[1m]` suffix or a second
  // `settings = { enableWorkflows` literal would mean two sources of truth for the same decision.
  const source = readFileSync(new URL('../src/agentd.mjs', import.meta.url), 'utf8')
  // Assert on booleans, not the 300KB source, so a failure reports the rule instead of the file.
  const has = (pattern, description) =>
    assert.ok(pattern.test(source), `agentd.mjs must ${description}`)
  const lacks = (pattern, description) =>
    assert.ok(!pattern.test(source), `agentd.mjs must not ${description}`)

  has(/from '\.\/claude-turn-options\.mjs'/, 'import the Claude turn-options module')
  has(/buildClaudeQueryOptions\(/, 'build its Claude query options through the module')
  has(/parseClaudeTurnConfiguration\(/, 'validate the nested claude block through the module')
  lacks(/claude-opus-4-8\[1m\]/, 'resolve the [1m] context variant inline')
  lacks(/settings = \{ enableWorkflows/, 'build SDK settings inline')
})

test('a demoted skill is marked in the list the app advertises', () => {
  // The daemon annotates supportedCommands() from the same settings object it just built, so the
  // picker cannot advertise a skill as agent-usable on a lane that demoted it. Asserted against the
  // source because the annotation lives inside the streaming path, not a pure function.
  const agentd = readFileSync(new URL('../src/agentd.mjs', import.meta.url), 'utf8')

  assert.match(
    agentd,
    /const demotedSkills = new Set\(Object\.keys\(options\.settings\?\.skillOverrides \|\| \{\}\)\)/,
    'the annotation must read the settings this turn actually sent')
  assert.match(agentd, /agentInvocable: false/)

  assert.match(agentd, /const withSkillVisibility = \(cmds\) =>/)

  // BOTH publication paths carry it: the initial enumeration and the mid-session refresh. Marking
  // only the first would make the truth disappear the moment a skill set changed.
  const applied = agentd.match(/withSkillVisibility\(/g) || []
  assert.equal(applied.length, 2,
    'both the initial enumeration and the commands_changed refresh must annotate')
})
