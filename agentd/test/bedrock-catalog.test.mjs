import assert from 'node:assert/strict'
import test from 'node:test'
import { readFileSync } from 'node:fs'

import { normalizeBedrockCatalog } from '../src/bedrock-catalog.mjs'

// The fixture is a slice of a REAL `ListInferenceProfiles` response from a live account, not a
// hand-written approximation. That matters here more than usual: this module exists because a
// shipped model list was wrong three times, each time from a source that looked authoritative but
// was not the account.
const live = JSON.parse(
  readFileSync(new URL('./fixtures-bedrock-profiles.json', import.meta.url), 'utf8'))

test('one row per family, preferring the broadest scope', () => {
  // The account lists BOTH global. and us. profiles for opus-4-8 and opus-5. A picker showing each
  // twice would be asking the user to choose between two spellings of the same model.
  const entries = normalizeBedrockCatalog(live)
  assert.deepStrictEqual(entries.map((e) => e.id), [
    'global.anthropic.claude-opus-4-8',
    'global.anthropic.claude-opus-5',
    'us.anthropic.claude-opus-4-1-20250805-v1:0',
    'us.anthropic.claude-3-sonnet-20240229-v1:0',
  ])
})

test('a us. profile survives when the account has no global. one', () => {
  // Opus 4.1 and Claude 3 exist only as us. profiles. Preferring global must not mean requiring it.
  const ids = normalizeBedrockCatalog(live).map((e) => e.id)
  assert.ok(ids.includes('us.anthropic.claude-opus-4-1-20250805-v1:0'))
})

/// Same rule as Vertex: a managed or personal deployment is granted access per family, so the
/// newest profile an account can ADDRESS is often one it cannot yet INVOKE.
test('the cold-start default is the conservative generation, not the newest', () => {
  const entries = normalizeBedrockCatalog(live)
  assert.strictEqual(entries[0].id, 'global.anthropic.claude-opus-4-8')
  assert.strictEqual(entries.filter((e) => e.isDefault).length, 1)
  assert.strictEqual(entries[0].isDefault, true)
})

test('ids are the invokable inference profiles, never Anthropic or bare foundation ids', () => {
  for (const { id } of normalizeBedrockCatalog(live)) {
    assert.ok(/^(global|us|eu|apac)\.anthropic\./.test(id), id)
    assert.ok(!/^claude-/.test(id), `${id} is an Anthropic API id`)
    assert.ok(!/^anthropic\./.test(id), `${id} is a bare foundation id — not invokable on demand`)
  }
})

test('a family this build has never heard of is still offered', () => {
  // The entire point of asking the account. A model Anthropic ships after this build must be
  // selectable, labelled by whatever the account calls it.
  const entries = normalizeBedrockCatalog({
    inferenceProfileSummaries: [{
      inferenceProfileId: 'global.anthropic.claude-nova-9',
      inferenceProfileName: 'Global Anthropic Claude Nova 9',
      status: 'ACTIVE',
    }],
  })
  assert.strictEqual(entries.length, 1)
  assert.strictEqual(entries[0].id, 'global.anthropic.claude-nova-9')
  assert.strictEqual(entries[0].label, 'Global Anthropic Claude Nova 9')
})

test('Fable 5.1 is labeled as its own generation instead of collapsing into Fable 5', () => {
  const entries = normalizeBedrockCatalog({
    inferenceProfileSummaries: [
      { inferenceProfileId: 'global.anthropic.claude-fable-5', status: 'ACTIVE' },
      { inferenceProfileId: 'us.anthropic.claude-fable-5-1', status: 'ACTIVE' },
    ],
  })

  assert.deepStrictEqual(entries.map(({ id, label }) => ({ id, label })), [
    { id: 'global.anthropic.claude-fable-5', label: 'Fable 5' },
    { id: 'us.anthropic.claude-fable-5-1', label: 'Fable 5.1' },
  ])
})

test('non-Anthropic and non-ACTIVE profiles are left out', () => {
  const entries = normalizeBedrockCatalog({
    inferenceProfileSummaries: [
      { inferenceProfileId: 'global.openai.gpt-5.6-sol', status: 'ACTIVE' },
      { inferenceProfileId: 'global.anthropic.claude-opus-5', status: 'INACTIVE' },
      { inferenceProfileId: 'global.anthropic.claude-opus-4-8', status: 'ACTIVE' },
    ],
  })
  // A non-ACTIVE profile cannot serve a turn, so offering it would be offering a failure.
  assert.deepStrictEqual(entries.map((e) => e.id), ['global.anthropic.claude-opus-4-8'])
})

test('no effort or capability metadata is invented', () => {
  // Bedrock reports none. Claiming some would be a guess dressed as discovery.
  for (const entry of normalizeBedrockCatalog(live)) {
    assert.deepStrictEqual(entry.efforts, [])
    assert.deepStrictEqual(entry.capabilities, [])
  }
})

test('a malformed or empty response yields nothing rather than throwing', () => {
  for (const bad of [null, {}, { inferenceProfileSummaries: null }, { inferenceProfileSummaries: [] },
                     { inferenceProfileSummaries: ['nope', { status: 'ACTIVE' }] }]) {
    assert.deepStrictEqual(normalizeBedrockCatalog(bad), [])
  }
})
