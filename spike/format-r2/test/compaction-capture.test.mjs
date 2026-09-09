import test from 'node:test'
import assert from 'node:assert/strict'
import { fileURLToPath } from 'node:url'
import path from 'node:path'
import { runComparison } from '../run.mjs'

const fixture = path.join(
  path.dirname(fileURLToPath(import.meta.url)),
  '..', '..', '..', 'agentd', 'test', 'fixtures',
  'activity-agents-compaction-fixture.mjs')

// One capture shared across every assertion. This fixture deliberately exercises the real
// provider-neutral compaction wire path, including pre/post context samples and streamed output.
const run = await runComparison(fixture)

test('capture path preserves the authoritative compaction boundary as a canonical event', () => {
  const compactions = run.canonical.events.filter((event) => event.kind === 'compaction')
  assert.deepEqual(compactions.map((event) => ({
    trigger: event.trigger,
    preTokens: event.preTokens,
    postTokens: event.postTokens,
  })), [{ trigger: 'auto', preTokens: 182000, postTokens: 51000 }])

  const orderedContext = run.canonical.events
    .filter((event) => event.kind === 'context_usage' || event.kind === 'compaction')
    .map((event) => event.kind === 'compaction' ? 'compaction' : event.contextTokens)
  assert.deepEqual(
    orderedContext,
    [42000, 182000, 'compaction', 51000, 68000],
    'the boundary must remain ordered between its pre- and post-compaction context samples')
})

test('all semantic roots round-trip the captured compaction, with draft gaps ledgered', () => {
  for (const [root, result] of Object.entries(run.results.roots)) {
    assert.deepEqual(result.structuralMisses, [], `${root}: captured compaction must survive`)
    assert.deepEqual(
      result.unclassifiedDifferences, [],
      `${root}: exact differences must be fail-closed and classified`)
    assert.equal(result.differences.length, result.declaredPrototypeGaps.length)
  }

  for (const root of ['A:vcon+agent_session', 'B:acr-vac']) {
    assert.ok(
      run.results.roots[root].extensions.some((entry) => entry.includes('context compaction')),
      `${root}: non-native compaction encoding must remain an explicit extension`)
    assert.ok(
      run.results.roots[root].extensions.some((entry) => entry.includes('context usage')),
      `${root}: non-native context samples must remain explicit extensions`)
  }
  assert.ok(
    run.results.roots['B:acr-vac'].declaredPrototypeGaps.some(
      (gap) => gap.code === 'prototype-decoder-omits-tool-input'),
    'the activity fixture must expose decoder loss of already-encoded tool input')
  assert.deepEqual(run.results.roots['C:canonical-graph'].extensions, [])
})
