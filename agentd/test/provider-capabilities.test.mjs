import assert from 'node:assert/strict'
import test from 'node:test'

import {
  PROVIDER_CAPABILITY_ADAPTER_REVISION,
  currentProviderCapabilities,
} from '../src/provider-capabilities.mjs'

function byID(snapshot, id) {
  return snapshot.capabilities.find((capability) => capability.id === id)
}

test('Claude preserves provider model evidence while separating unimplemented adapter features', () => {
  const snapshot = currentProviderCapabilities({
    provider: 'anthropic',
    authMode: 'subscription',
    modelEntry: {
      id: 'claude-fixture',
      efforts: ['low', 'medium', 'xhigh'],
      capabilities: ['effort', 'adaptive_thinking', 'fast_mode'],
    },
  })

  assert.equal(snapshot.adapterRevision, PROVIDER_CAPABILITY_ADAPTER_REVISION)
  assert.deepEqual(byID(snapshot, 'reasoning_effort'), {
    id: 'reasoning_effort',
    providerAvailability: 'available',
    mechanicianSupport: 'implemented',
    symmetry: 'symmetric',
    operation: 'query.options.effort',
    constraints: { model: 'claude-fixture', levels: 'low,medium,xhigh' },
    disclosures: {},
    evidence: {
      source: 'providerResponse',
      operation: 'supportedModels',
      revision: PROVIDER_CAPABILITY_ADAPTER_REVISION,
    },
  })
  assert.equal(byID(snapshot, 'adaptive_thinking').providerAvailability, 'available')
  assert.equal(byID(snapshot, 'adaptive_thinking').mechanicianSupport, 'unimplemented')
  assert.equal(byID(snapshot, 'fast_mode').mechanicianSupport, 'unimplemented')
  assert.equal(byID(snapshot, 'prompt_suggestions').mechanicianSupport, 'implemented')
  assert.equal(byID(snapshot, 'turn_guidance').operation, 'streaming_input.priority_next')

  const ultracode = byID(snapshot, 'claude_ultracode')
  assert.equal(ultracode.providerAvailability, 'unknown')
  assert.equal(ultracode.mechanicianSupport, 'implemented')
  assert.equal(ultracode.evidence.source, 'adapterStatic')
})

test('Anthropic API exposes Claude Ultra through the SDK adapter when xhigh is available', () => {
  const snapshot = currentProviderCapabilities({
    provider: 'anthropic',
    authMode: 'apikey',
    modelEntry: {
      id: 'claude-api-fixture',
      efforts: ['medium', 'xhigh'],
      capabilities: ['effort'],
    },
  })

  assert.equal(byID(snapshot, 'reasoning_effort').providerAvailability, 'available')
  assert.equal(byID(snapshot, 'prompt_suggestions').mechanicianSupport, 'implemented')
  const ultracode = byID(snapshot, 'claude_ultracode')
  assert.equal(ultracode.mechanicianSupport, 'implemented')
  assert.equal(ultracode.operation, 'query.settings.ultracode')
  assert.equal(ultracode.evidence.operation, 'Claude apikey adapter')
})

test('Codex treats model/list effort and Ultra as provider evidence', () => {
  const snapshot = currentProviderCapabilities({
    provider: 'codex',
    authMode: 'subscription',
    modelEntry: {
      id: 'codex-fixture',
      efforts: ['low', 'high', 'ultra'],
      capabilities: ['effort', 'ultra'],
    },
  })

  const effort = byID(snapshot, 'reasoning_effort')
  assert.equal(effort.providerAvailability, 'available')
  assert.equal(effort.mechanicianSupport, 'implemented')
  assert.equal(effort.evidence.operation, 'model/list')
  const ultra = byID(snapshot, 'ultra')
  assert.equal(ultra.providerAvailability, 'available')
  assert.equal(ultra.mechanicianSupport, 'implemented')
  assert.equal(ultra.operation, 'turn/start.effort')
  assert.deepEqual(byID(snapshot, 'native_review'), {
    id: 'native_review',
    providerAvailability: 'available',
    mechanicianSupport: 'implemented',
    symmetry: 'providerSpecific',
    operation: 'review/start',
    constraints: { target: 'uncommittedChanges', delivery: 'inline' },
    disclosures: { output: 'providerAuthored' },
    evidence: {
      source: 'providerContract',
      operation: 'Codex App Server review/start',
      revision: PROVIDER_CAPABILITY_ADAPTER_REVISION,
    },
  })
  assert.equal(byID(snapshot, 'turn_guidance').operation, 'turn/steer')
  assert.equal(byID(snapshot, 'prompt_suggestions'), undefined)
})

test('OpenAI API does not mislabel static adapter effort metadata as provider truth', () => {
  const snapshot = currentProviderCapabilities({
    provider: 'openai',
    authMode: 'apikey',
    modelEntry: {
      id: 'gpt-fixture',
      efforts: ['low', 'medium', 'high'],
      capabilities: ['effort'],
    },
  })

  const effort = byID(snapshot, 'reasoning_effort')
  assert.equal(effort.providerAvailability, 'unknown')
  assert.equal(effort.mechanicianSupport, 'implemented')
  assert.equal(effort.evidence.source, 'adapterStatic')
  assert.equal(effort.evidence.operation, 'normalizeOpenAICatalog')
  assert.equal(byID(snapshot, 'turn_guidance'), undefined)
  assert.equal(byID(snapshot, 'ultra'), undefined)
})

test('unknown provider capability ids survive but remain unimplemented', () => {
  const snapshot = currentProviderCapabilities({
    provider: 'codex',
    authMode: 'subscription',
    modelEntry: {
      id: 'codex-future',
      capabilities: ['Future Mode!?', 'Future Mode!?'],
    },
  })

  const future = byID(snapshot, 'provider.future_mode')
  assert.ok(future)
  assert.equal(future.providerAvailability, 'available')
  assert.equal(future.mechanicianSupport, 'unimplemented')
  assert.equal(snapshot.capabilities.filter((item) => item.id === future.id).length, 1)
})

test('empty catalogs retain route-contract Review but do not invent compaction, hosted tools, or effort', () => {
  const openAI = currentProviderCapabilities({
    provider: 'openai', authMode: 'apikey', modelEntry: {},
  })
  assert.deepEqual(openAI.capabilities, [])

  const codex = currentProviderCapabilities({
    provider: 'codex', authMode: 'subscription', modelEntry: {},
  })
  assert.deepEqual(codex.capabilities.map((item) => item.id), ['native_review', 'turn_guidance'])
  assert.equal(byID(codex, 'native_review').operation, 'review/start')
  for (const forbidden of ['manual_compaction', 'hosted_tools']) {
    assert.equal(byID(codex, forbidden), undefined)
  }
})

test('native Review is never advertised on Claude or direct API routes', () => {
  for (const route of [
    { provider: 'anthropic', authMode: 'subscription' },
    { provider: 'anthropic', authMode: 'apikey' },
    { provider: 'openai', authMode: 'apikey' },
  ]) {
    assert.equal(byID(currentProviderCapabilities(route), 'native_review'), undefined)
  }
})

test('invalid routes fail closed', () => {
  assert.throws(
    () => currentProviderCapabilities({ provider: 'unknown', authMode: 'apikey' }),
    /unsupported provider capability route/i,
  )
  assert.throws(
    () => currentProviderCapabilities({ provider: 'codex', authMode: 'token' }),
    /unsupported provider capability auth mode/i,
  )
})

// ── Claude Opus 5 platform surfaces (plan Phase 0, O5-004) ──

test('Claude routes report the Opus 5 preview surfaces as experimental and unimplemented', () => {
  const snapshot = currentProviderCapabilities({
    provider: 'anthropic',
    authMode: 'apikey',
    modelEntry: { id: 'claude-opus-5', efforts: ['medium', 'high'], capabilities: ['effort', 'fast_mode'] },
  })

  // Provider availability and Mechanician support move independently: the SDK types these options
  // today, but nothing in the product can honor them until their own phase lands.
  for (const id of ['advisor', 'safety_refusal_fallback']) {
    assert.equal(byID(snapshot, id).providerAvailability, 'experimental', id)
    assert.equal(byID(snapshot, id).mechanicianSupport, 'unimplemented', id)
    assert.equal(byID(snapshot, id).operation, undefined, `${id} must claim no operation yet`)
  }

  assert.equal(byID(snapshot, 'advisor').constraints.advisorModel, 'claude-opus-5')
  assert.equal(byID(snapshot, 'advisor').disclosures.content, 'encryptedRedacted')
  assert.equal(byID(snapshot, 'advisor').disclosures.cost, 'premiumAdvisorTokens')

  // Recorded so a later reader cannot mistake the operational fallback option for this one.
  assert.equal(byID(snapshot, 'safety_refusal_fallback').constraints.distinctFrom, 'operational_fallback')

  // Receiving a supersession is not optional, which is why it is available upstream on every Claude
  // lane and carries no user control.
  assert.equal(byID(snapshot, 'refusal_supersession').providerAvailability, 'available')
  assert.equal(byID(snapshot, 'refusal_supersession').disclosures.control, 'none')

  // Fast stays unimplemented until its request mapping and observed-speed receipt land.
  assert.equal(byID(snapshot, 'fast_mode').mechanicianSupport, 'unimplemented')
})

test('a Vertex capability diagnostic completes and claims no preview support', () => {
  // Regression: this route used to THROW, failing the entire capability request for an enterprise
  // account rather than reporting which surfaces its route lacks.
  const snapshot = currentProviderCapabilities({
    provider: 'anthropic',
    authMode: 'vertex',
    modelEntry: {
      id: 'claude-opus-4-5@20250101',
      efforts: ['medium', 'high', 'xhigh'],
      // Even if an enterprise catalog claimed Fast, the route contract must win.
      capabilities: ['effort', 'fast_mode'],
    },
  })

  assert.equal(snapshot.adapterRevision, PROVIDER_CAPABILITY_ADAPTER_REVISION)
  for (const id of ['advisor', 'safety_refusal_fallback', 'fast_mode']) {
    assert.equal(byID(snapshot, id).providerAvailability, 'unavailable', id)
    assert.equal(byID(snapshot, id).mechanicianSupport, 'unimplemented', id)
  }
  // The route is honest, not crippled: provider-reported effort still works.
  assert.equal(byID(snapshot, 'reasoning_effort').mechanicianSupport, 'implemented')
  assert.equal(byID(snapshot, 'reasoning_effort').constraints.levels, 'medium,high,xhigh')
  // A supersession can still arrive on a Vertex session, so it is not marked unavailable.
  assert.equal(byID(snapshot, 'refusal_supersession').providerAvailability, 'available')
})

test('the Opus 5 preview surfaces never appear on a Codex or OpenAI route', () => {
  for (const [provider, authMode] of [['codex', 'subscription'], ['openai', 'apikey']]) {
    const snapshot = currentProviderCapabilities({
      provider,
      authMode,
      modelEntry: { id: 'other-model', efforts: ['medium'], capabilities: ['effort'] },
    })
    for (const id of ['advisor', 'safety_refusal_fallback', 'refusal_supersession']) {
      assert.equal(byID(snapshot, id), undefined, `${provider} must not report ${id}`)
    }
  }
})

test('vertex is rejected on a non-Claude provider', () => {
  assert.throws(
    () => currentProviderCapabilities({ provider: 'codex', authMode: 'vertex' }),
    /unsupported provider capability route/i,
  )
})
