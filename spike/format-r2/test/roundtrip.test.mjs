import test from 'node:test'
import assert from 'node:assert/strict'
import { fileURLToPath } from 'node:url'
import path from 'node:path'
import { runComparison } from '../run.mjs'
import { toCanonical } from '../canonical.mjs'

const fixture = path.join(
  path.dirname(fileURLToPath(import.meta.url)),
  '..', '..', '..', 'agentd', 'test', 'fixtures', 'nested-delegation-fixture.mjs')

// One capture shared across every assertion (the fixture waits real milliseconds).
const run = await runComparison(fixture)

test('canonical (root C) captures the full delegation graph as first-class facts', () => {
  const { canonical } = run
  const byTask = Object.fromEntries(canonical.agents.map((a) => [a.task, a]))
  const childA = byTask['Survey the persistence layer']
  const childB = byTask['Draft the migration order']
  const grandchild = byTask['Enumerate sidecar writers']
  const greatgrandchild = byTask['Hash the largest sidecars']
  assert.equal(childA.parentId, 'root')
  assert.equal(childB.parentId, 'root')
  assert.equal(grandchild.parentId, childA.id)
  assert.equal(greatgrandchild.parentId, grandchild.id)
  const portableIdentities = [
    ...canonical.sessionIds,
    ...canonical.agents.flatMap((agent) => [agent.id, agent.parentId]),
    ...canonical.events.flatMap((event) => [
      event.agentId, event.spawnedAgentId, event.recipientAgentId,
      event.completedAgentId, event.toolUseId, event.turnId, event.steeringId,
    ]),
  ].filter(Boolean)
  assert.doesNotMatch(portableIdentities.join('\n'), /child-a|child-b|grandchild-a1/,
    'provider control identifiers must not become portable record identities')

  const message = canonical.events.find((e) => e.kind === 'agent_message')
  assert.equal(message.agentId, childA.id)
  assert.equal(message.recipientAgentId, childB.id)
  assert.equal(
    message.recipientProvenance, 'inferred-from-tool-input',
    'the canonical model records HOW it knows, since the wire only implies the edge')
})

test('root A is inspectable vCon-shaped fit-gap evidence, not a conformance claim', () => {
  const { results } = run
  const { encodeVcon } = null ?? {}
  // Re-encode for direct structural checks.
  return import('../encode-vcon.mjs').then(async (m) => {
    const { vcon } = m.encodeVcon(run.canonical)
    assert.ok(vcon.uuid && vcon.created_at && Array.isArray(vcon.parties), 'core required keys')
    // One party per distinct agent is MUST; +1 for the user.
    assert.equal(vcon.parties.length, run.canonical.agents.length + 1)
    for (const d of vcon.dialog) {
      assert.ok(d.start, 'core: every dialog entry requires start')
      assert.ok(Array.isArray(d.parties), 'core: every dialog entry requires parties')
      assert.ok(['base64url', 'json', 'none'].includes(d.encoding))
    }
    const trace = vcon.analysis[0]
    for (const key of ['type', 'dialog', 'vendor', 'product', 'schema', 'encoding', 'body']) {
      assert.ok(trace[key] !== undefined, `agent_trace MUST set ${key}`)
    }
    assert.equal(typeof trace.body, 'object', 'body is an OBJECT (recorded deviation from the stringified example)')
    assert.ok(trace.body.session, 'VAC body uses the CDDL key `session`, not `session-trace`')
    const ledger = m.encodeVcon(run.canonical).ledger
    assert.ok(
      ledger.deviations.some((entry) => entry.includes('omit the Agent Session')),
      'missing required party metadata must remain a blocker, not a silent success')
    assert.ok(
      ledger.deviations.some((entry) => entry.includes('does not cross-check')),
      'duplicated dialog/trace truth must be declared')
  })
})

test('root B private prototype retains nesting while declaring its CDDL mismatch', async () => {
  const m = await import('../encode-acr.mjs')
  const { record, ledger } = m.encodeACR(run.canonical)
  assert.ok(record.version && record.id && record.session, 'VAC required top-level members')
  const entries = record.session.entries
  const byId = Object.fromEntries(entries.map((e) => [e['entry-id'], e]))
  const byTask = Object.fromEntries(run.canonical.agents.map((a) => [a.task, a]))
  // Find the grandchild's spawn entry and walk up: its parent chain must reach child A's spawn.
  const spawnOf = (agent) => entries.find(
    (e) => e['event-type'] === 'agent-spawn' && e.data['x-agent-id'] === agent)
  const grandSpawn = spawnOf(byTask['Enumerate sidecar writers'].id)
  assert.ok(grandSpawn['parent-id'], 'nested spawn parents under the spawning agent')
  assert.equal(byId[grandSpawn['parent-id']].data['x-agent-id'],
    byTask['Survey the persistence layer'].id)
  const greatSpawn = spawnOf(byTask['Hash the largest sidecars'].id)
  assert.equal(byId[greatSpawn['parent-id']].data['x-agent-id'],
    byTask['Enumerate sidecar writers'].id)
  assert.ok(
    ledger.deviations.some((entry) => entry.includes('not VAC -00 CDDL-shaped')),
    'a self-consistent private decoder is not standards conformance')
})

test('structural survival never hides field-level prototype gaps', () => {
  const { results } = run
  for (const [root, r] of Object.entries(results.roots)) {
    assert.deepEqual(r.structuralMisses, [], `${root}: event skeleton must survive`)
    assert.deepEqual(
      r.unclassifiedDifferences, [],
      `${root}: every exact field difference must be declared, never silently ignored`)
    assert.equal(
      r.differences.length, r.declaredPrototypeGaps.length,
      `${root}: the field ledger must cover every observed difference`)
  }
  const a = results.roots['A:vcon+agent_session']
  const b = results.roots['B:acr-vac']
  // The documented holes MUST appear as explicit ledger entries — the whole point of the spike
  // is evidence, and a silent success here would mean the encoder smuggled or dropped a fact.
  assert.ok(
    b.extensions.some((e) => e.includes('agent-to-agent')),
    'the recipient edge must be declared as extension-carried')
  assert.ok(
    b.extensions.some((e) => e.includes('agent-spawn')),
    'spawn lifecycle must be declared as extension-carried')
  assert.ok(
    b.losses.some((l) => l.includes('agent-meta')),
    'the one-agent-meta-per-record limitation must be a recorded loss')
  assert.ok(
    a.deviations.some((d) => d.includes('session-trace')),
    'the session vs session-trace divergence must be a recorded deviation')
  assert.ok(a.deviations.length >= 3, 'root A carries the known composition deviations')
  const codes = new Set(b.declaredPrototypeGaps.map((gap) => gap.code))
  for (const code of [
    'prototype-decoder-omits-agent-task',
    'prototype-decoder-omits-timestamp',
    'prototype-encoding-omits-time-provenance',
    'prototype-encoding-omits-recipient-provenance',
    'prototype-encoding-omits-session-identity-provenance',
    'prototype-decoder-omits-agent-message-summary',
  ]) assert.ok(codes.has(code), `nested fixture must exercise ${code}`)
  assert.equal(codes.has('prototype-encoding-omits-tool-result-status'), false,
    'the prototype now retains explicit tool/agent result status rather than ledgering its loss')
  assert.ok(
    b.extensions.some((entry) => entry.includes('result lifecycle')),
    'status/outcome fidelity must be declared extension-carried, never mistaken for native VAC')
})

test('portable identity minting rejects conflicting provider aliases and scopes reused ids', () => {
  const at = '2026-08-03T12:00:00.000Z'
  const capture = (events) => ({
    prompt: 'identity test', promptObservedAt: at,
    producer: { name: 'test', version: '1', build: '1' },
    profile: { id: 'test', version: '1' },
    events: events.map((event, index) => ({ seq: index + 1, observedAt: at, event })),
  })
  assert.throws(() => toCanonical(capture([
    { type: 'turn_started', id: 'provider-turn' },
    { type: 'workflow_update', id: 'provider-turn', taskId: 'task-a', toolUseId: 'tool-x' },
    { type: 'workflow_update', id: 'provider-turn', taskId: 'task-b', toolUseId: 'tool-x' },
  ])), /one provider tool id named two authoritative child tasks/)

  const namespaced = toCanonical(capture([
    { type: 'turn_started', id: 'provider-turn' },
    { type: 'tool_use', id: 'provider-turn', name: 'Task', toolUseId: 'shared-raw-id', input: {} },
    {
      type: 'workflow_update', id: 'provider-turn', taskId: 'shared-raw-id',
      toolUseId: 'different-tool-id', status: 'running',
    },
  ]))
  assert.equal(namespaced.agents.filter((agent) => agent.id !== 'root').length, 2,
    'equal raw task/tool strings are distinct until an explicit correlation event joins them')

  const canonical = toCanonical(capture([
    { type: 'turn_started', id: 'provider-turn-a' },
    { type: 'tool_use', id: 'provider-turn-a', name: 'Task', toolUseId: 'reused-child', input: {} },
    { type: 'done', id: 'provider-turn-a' },
    { type: 'turn_started', id: 'provider-turn-b' },
    { type: 'tool_use', id: 'provider-turn-b', name: 'Task', toolUseId: 'reused-child', input: {} },
    { type: 'done', id: 'provider-turn-b' },
  ]))
  assert.equal(canonical.agents.filter((agent) => agent.id !== 'root').length, 2)
  assert.deepEqual(
    canonical.events.filter((event) => event.kind === 'turn_started').map((event) => event.turnId),
    ['turn-1', 'turn-2'])
})
