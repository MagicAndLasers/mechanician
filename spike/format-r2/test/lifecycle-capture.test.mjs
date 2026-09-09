import test from 'node:test'
import assert from 'node:assert/strict'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { canonicalDigest } from '../canonical-field-contract.mjs'
import { toCanonical } from '../canonical.mjs'
import { captureTurn } from '../capture.mjs'
import { runComparison } from '../run.mjs'

const fixture = path.join(
  path.dirname(fileURLToPath(import.meta.url)),
  '..', '..', '..', 'agentd', 'test', 'fixtures', 'format-review-lifecycle-fixture.mjs')

const deterministicTime = (sequence) =>
  new Date(Date.UTC(2026, 7, 3, 12, 0, sequence)).toISOString()
const steeringRequests = [{
  steerId: 'steer-accepted', prompt: 'Please include the accepted steering fact.',
}, {
  steerId: 'steer-rejected', prompt: 'This request is rejected by the fixture.',
}]
const successOptions = {
  prompt: 'success',
  promptObservedAt: '2026-08-03T11:59:59.000Z',
  observedAtForSequence: deterministicTime,
  requireQuiescence: true,
  steeringRequests,
}

const success = await runComparison(fixture, successOptions)
const rootOnly = await runComparison(fixture, {
  prompt: 'success', observedAtForSequence: deterministicTime,
})
const error = await runComparison(fixture, {
  prompt: 'error', observedAtForSequence: deterministicTime, requireQuiescence: true,
})
const interrupted = await runComparison(fixture, {
  prompt: 'interrupted', observedAtForSequence: deterministicTime, requireQuiescence: true,
})

test('capture envelope is exact, immutable, and excludes every provider resume handle', () => {
  assert.deepEqual(success.canonical.producer, {
    name: 'Mechanician R2 capture harness', version: '0.23.0', build: '207',
  })
  assert.deepEqual(success.canonical.profile, {
    id: 'ai.mechanician.conversation-record.native-graph', version: '0-spike',
  })
  assert.equal(success.canonical.events[0].observedAt, '2026-08-03T11:59:59.000Z')
  for (const run of [success, error]) {
    assert.doesNotMatch(JSON.stringify(run.canonical), /PRIVATE-GATE-C-(?:RESUME|ERROR)-HANDLE/)
  }
  assert.equal(success.canonical.sessionIds.length, 1)
  assert.equal(success.canonical.events.find((event) => event.kind === 'session')
    .sessionIdentityProvenance, 'minted-from-boundary-order')
  assert.ok(Object.isFrozen(success.capture))
  assert.ok(Object.isFrozen(success.capture.events))
  assert.throws(() => { success.capture.events.push('late mutation') }, /extensible|read only|object/i)

  assert.throws(() => captureTurn(fixture, {
    producer: { name: 'test', version: '1', build: '1', secret: 'not allowed' },
  }), /producer must contain exactly/)
  assert.throws(() => captureTurn(fixture, { promptObservedAt: 'not-a-time' }),
    /promptObservedAt/)
})

test('quiescence requires every known child terminal and merges provisional aliases', () => {
  assert.equal(success.capture.quiescence.root.type, 'done')
  assert.deepEqual(
    success.capture.quiescence.children.map((child) => [child.id, child.parentId, child.state]),
    [
      ['child-after-root', null, 'completed'],
      ['late-discovered-child', null, 'completed'],
      ['nested-before-root', 'parent-before-root', 'completed'],
      ['parent-before-root', null, 'completed'],
    ])
  assert.equal(
    success.capture.quiescence.children.some((child) => child.id === 'after-tool'), false,
    'the provisional alias must not remain as a second active child')

  const byTask = Object.fromEntries(success.canonical.agents.map((agent) => [agent.task, agent]))
  const parent = byTask['Coordinate lifecycle evidence']
  const nested = byTask['Inspect nested lifecycle evidence']
  assert.equal(nested.parentId, parent.id)
  assert.equal(success.canonical.agents.filter((agent) => agent.id !== 'root').length, 4)
  assert.equal(success.canonical.events.filter((event) => event.kind === 'agent_spawn').length, 4)

  const metadataOnly = success.canonical.events.find((event) =>
    event.kind === 'agent_lifecycle' && event.summary === 'Metadata refreshed')
  assert.equal(metadataOnly.state, null, 'phase is not fabricated into lifecycle state')
  assert.deepEqual(
    success.canonical.events.map((event) => event.eventId),
    success.canonical.events.map((_, index) => `event-${index + 1}`))
})

test('root completion alone demonstrably truncates late provider lifecycle', () => {
  const rootTerminal = success.canonical.events.findIndex(
    (event) => event.kind === 'turn_completed')
  const afterRoot = success.canonical.events.filter((event, index) =>
    index > rootTerminal && event.kind === 'agent_lifecycle')
  assert.ok(afterRoot.some((event) => event.state === 'completed'))
  assert.ok(afterRoot.some((event) => event.description === 'Discovered after the root'))
  assert.equal(rootOnly.canonical.events.some((event) =>
    event.kind === 'agent_lifecycle' && event.description === 'Discovered after the root'), false)
})

test('actual steering requests and responses retain content, roles, and portable correlation', () => {
  assert.equal(success.capture.outboundRequests.length, 2)
  const requests = success.canonical.events.filter((event) => event.kind === 'steering_request')
  const responses = success.canonical.events.filter((event) => event.kind === 'steering')
  assert.deepEqual(requests.map((event) => [event.agentId, event.responderAgentId, event.text]), [
    ['user', 'root', 'Please include the accepted steering fact.'],
    ['user', 'root', 'This request is rejected by the fixture.'],
  ])
  assert.deepEqual(responses.map((event) => [event.agentId, event.requesterAgentId, event.state]), [
    ['root', 'user', 'accepted'], ['root', 'user', 'rejected'],
  ])
  assert.deepEqual(requests.map((event) => event.steeringId),
    responses.map((event) => event.steeringId))
  assert.deepEqual(requests.map((event) => event.steeringId), ['steering-1', 'steering-2'])
})

test('usage, provider failure, and interruption remain distinct terminal facts', () => {
  const usage = success.canonical.events.find((event) => event.kind === 'usage')
  assert.deepEqual({
    input: usage.inputTokens, cached: usage.cachedInputTokens,
    output: usage.outputTokens, reasoning: usage.reasoningOutputTokens,
  }, { input: 1200, cached: 400, output: 80, reasoning: 20 })

  const providerError = error.canonical.events.find((event) => event.kind === 'provider_error')
  assert.deepEqual({
    kind: providerError.errorKind,
    rateLimitType: providerError.rateLimitType,
    resetsAt: providerError.resetsAt,
  }, { kind: 'usage_limit', rateLimitType: 'five_hour', resetsAt: 1786000000 })
  assert.equal(error.canonical.events.some((event) => event.kind === 'turn_failed'), true)
  assert.equal(error.canonical.events.some((event) => event.kind === 'turn_completed'), false)

  const terminal = interrupted.canonical.events.find((event) => event.kind === 'turn_stopped')
  assert.ok(terminal, 'interruption is a stopped terminal, never a successful completion flag')
  assert.equal(interrupted.canonical.events.some((event) => event.kind === 'turn_completed'), false)
})

test('all roots retain the selected skeleton and ledger every exact prototype gap', () => {
  for (const run of [success, error, interrupted]) {
    for (const [root, evidence] of Object.entries(run.results.roots)) {
      assert.deepEqual(evidence.structuralMisses, [], `${root}: lifecycle skeleton`)
      assert.deepEqual(evidence.unclassifiedDifferences, [], `${root}: field ledger`)
      assert.equal(evidence.differences.length, evidence.declaredPrototypeGaps.length)
    }
  }
  for (const root of ['A:vcon+agent_session', 'B:acr-vac']) {
    assert.ok(success.results.roots[root].extensions.some((entry) =>
      entry.includes('agent lifecycle')))
    assert.ok(success.results.roots[root].extensions.some((entry) =>
      entry.includes('steering request content')))
    assert.ok(error.results.roots[root].extensions.some((entry) =>
      entry.includes('provider error lifecycle')))
  }
  assert.match(success.results.roots['C:canonical-graph'].note,
    /selected canonical object identity only/)
})

test('quiescent lifecycle capture is byte-canonical under a deterministic clock', async () => {
  const second = await runComparison(fixture, successOptions)
  assert.equal(canonicalDigest(success.canonical), canonicalDigest(second.canonical))
})

test('capture fails closed on malformed, premature, late, and invalid completion', async () => {
  await assert.rejects(captureTurn(fixture, { prompt: 'malformed' }), /malformed NDJSON/)
  await assert.rejects(captureTurn(fixture, {
    prompt: 'premature-quiescence', requireQuiescence: true,
  }), /active children/)
  await assert.rejects(captureTurn(fixture, {
    prompt: 'late-root-content', requireQuiescence: true,
  }), /root content delta arrived after terminal/)
  await assert.rejects(captureTurn(fixture, {
    prompt: 'success', completeWhen: () => { throw new Error('completion policy failed') },
  }), /completion policy failed/)
})

test('later explicit nested parentage wins while portable call correlation remains intact', () => {
  const at = (second) => new Date(Date.UTC(2026, 7, 3, 13, 0, second)).toISOString()
  const wire = [
    { type: 'turn_started', id: 'private-turn-handle' },
    {
      type: 'tool_use', id: 'private-turn-handle', toolUseId: 'parent-provider-handle',
      name: 'Task', input: { subagent_type: 'Explore', description: 'Parent work' },
    },
    {
      type: 'workflow_update', id: 'private-turn-handle', phase: 'started',
      taskId: 'child-provider-task', toolUseId: 'child-provider-tool',
      taskType: 'codex_subagent', subagentType: 'Explore',
      description: 'Nested work', status: 'running',
    },
    {
      type: 'tool_use', id: 'private-turn-handle', toolUseId: 'child-provider-tool',
      parentToolUseId: 'parent-provider-handle', name: 'Task',
      input: { subagent_type: 'Explore', description: 'Nested work' },
    },
    {
      type: 'tool_result', id: 'private-turn-handle', toolUseId: 'child-provider-tool',
      parentToolUseId: 'parent-provider-handle', status: 'success',
      result: 'Nested work complete.',
    },
    { type: 'done', id: 'private-turn-handle' },
  ]
  const canonical = toCanonical({
    prompt: 'nested', promptObservedAt: null, outboundRequests: [],
    producer: { name: 'test', version: '1', build: '1' },
    profile: { id: 'test', version: '1' },
    events: wire.map((event, index) => ({ seq: index + 1, observedAt: at(index + 1), event })),
  })
  const parent = canonical.agents.find((agent) => agent.task === 'Parent work')
  const child = canonical.agents.find((agent) => agent.task === 'Nested work')
  assert.equal(child.parentId, parent.id)
  assert.equal(child.parentageProvenance, 'explicit-parent-tool-use-id')
  const childSpawn = canonical.events.find(
    (event) => event.kind === 'agent_spawn' && event.spawnedAgentId === child.id)
  const completion = canonical.events.find((event) => event.kind === 'agent_call_result')
  assert.equal(childSpawn.agentId, parent.id)
  assert.equal(completion.completedAgentId, child.id)
  assert.equal(completion.outcome, 'succeeded')
  assert.equal(completion.toolUseId, childSpawn.toolUseId)
  const identityFields = [
    ...canonical.agents.flatMap((agent) => [agent.id, agent.parentId]),
    ...canonical.events.flatMap((event) => [
      event.agentId, event.turnId, event.toolUseId, event.completedAgentId,
    ]),
  ].filter(Boolean).join('\n')
  assert.doesNotMatch(identityFields, /private-|provider-/)
})
