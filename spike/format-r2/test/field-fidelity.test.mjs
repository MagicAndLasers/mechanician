import test from 'node:test'
import assert from 'node:assert/strict'
import crypto from 'node:crypto'
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import {
  REVIEWED_CAPTURE_BASELINE_EXCLUSIONS,
  REVIEWED_CAPTURE_EVENT_FIELDS,
  REVIEWED_CAPTURE_OUTBOUND_REQUEST_FIELDS,
  REVIEWED_CAPTURE_PRODUCTION_SOURCE_FIELDS,
  REVIEWED_CAPTURE_SOURCE_PINS,
  REVIEWED_SIDECAR_OBSERVED_FIELDS,
  REVIEWED_SIDECAR_PRODUCTION_FIELDS,
  auditReviewedCaptureSurface,
  auditSidecarFields,
  canonicalDigest,
  classifyReviewedCaptureField,
  classifySidecarField,
  compareCanonicalFields,
  reviewedCaptureFieldKey,
} from '../canonical-field-contract.mjs'
import { runComparison } from '../run.mjs'
import { captureTurn } from '../capture.mjs'

const repo = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', '..')

test('every reviewed sidecar field has an explicit fail-closed disposition', () => {
  const dispositions = REVIEWED_SIDECAR_OBSERVED_FIELDS.map((field) =>
    classifySidecarField(field))
  assert.equal(REVIEWED_SIDECAR_OBSERVED_FIELDS.length, 114)
  assert.ok(dispositions.every(Boolean))
  assert.equal(dispositions.filter((item) => item.classification === 'canonical').length, 40)
  assert.equal(dispositions.filter((item) => item.classification === 'private-local').length, 3)
  assert.equal(
    dispositions.filter((item) => item.classification === 'intentionally-omitted').length, 7)
  assert.equal(
    dispositions.filter((item) => item.classification === 'derived-projection').length, 9)
  assert.equal(
    dispositions.filter((item) => item.classification === 'not-yet-captured').length, 55,
    'known unmapped facts are format-review gaps, never passes')
  assert.equal(dispositions.filter((item) => item.classification === 'unknown').length, 0)

  const drift = auditSidecarFields([{ futureCriticalFact: 'must not leak through' }])
  assert.deepEqual(drift.unclassified, ['futureCriticalFact'])
})

test('optional production sidecar fields are reviewed separately from observed corpus evidence', () => {
  assert.equal(REVIEWED_SIDECAR_PRODUCTION_FIELDS.length, 71)
  assert.ok(REVIEWED_SIDECAR_PRODUCTION_FIELDS.every(
    (field) => !REVIEWED_SIDECAR_OBSERVED_FIELDS.includes(field)),
  'schema review must not be reported as corpus observation')
  const dispositions = REVIEWED_SIDECAR_PRODUCTION_FIELDS.map((field) =>
    classifySidecarField(field))
  assert.ok(dispositions.every(Boolean))
  assert.equal(dispositions.filter((item) => item.classification === 'canonical').length, 36)
  assert.equal(
    dispositions.filter((item) => item.classification === 'derived-projection').length,
    20)
  assert.equal(
    dispositions.filter((item) => item.classification === 'intentionally-omitted').length,
    3)
  assert.equal(
    dispositions.filter((item) => item.classification === 'not-yet-captured').length,
    4)
  assert.equal(
    dispositions.filter((item) => item.classification === 'private-local').length,
    8)
  assert.equal(dispositions.filter((item) => item.classification === 'unknown').length, 0)

  assert.ok(REVIEWED_SIDECAR_PRODUCTION_FIELDS.includes(
    'messages[].verifiedKnowledgeReceipt'))
  const receipt = classifySidecarField('messages[].verifiedKnowledgeReceipt')
  assert.equal(receipt?.classification, 'private-local')
  assert.match(receipt?.reason ?? '', /decode, revalidate, and remint/)

  assert.ok(REVIEWED_SIDECAR_PRODUCTION_FIELDS.includes(
    'messages[].learnedSkillApplicationReceipt'))
  const learnedSkillReceipt = classifySidecarField(
    'messages[].learnedSkillApplicationReceipt')
  assert.equal(learnedSkillReceipt?.classification, 'private-local')
  assert.match(learnedSkillReceipt?.reason ?? '', /Conversation, turn, user-entry, Workspace/)
  assert.match(learnedSkillReceipt?.reason ?? '', /decode, revalidate, and remint/)

  assert.equal(
    classifySidecarField('messages[].helpConsultationReceipt')?.classification,
    'not-yet-captured')
  assert.equal(
    classifySidecarField('messages[].helpConsultationTurnID')?.classification,
    'intentionally-omitted')
})

test('C1.4 persisted chronology fields are individually classified', () => {
  for (const path of [
    'messages[].id',
    'messages[].captureOrdinal',
    'messages[].toolResultCaptureOrdinal',
    'messages[].toolTerminalCaptureOrdinal',
    'messages[].interactionResponseCaptureOrdinal',
    'messages[].interactionAcknowledgedCaptureOrdinal',
    'messages[].supersessionCaptureOrdinal',
    'messages[].supersessionEventID',
    'messages[].supersededByEntryID',
    'messages[].interactionClosure.captureOrdinal',
  ]) {
    assert.equal(classifySidecarField(path)?.classification, 'canonical', path)
  }
  for (const path of [
    'captureOrdinalHighWatermark',
    'subagents.*.startedCaptureOrdinal',
    'subagents.*.endedCaptureOrdinal',
  ]) {
    assert.equal(classifySidecarField(path)?.classification, 'derived-projection', path)
  }
  for (const path of [
    'agentActivity[].id',
    'agentActivity[].captureOrdinal',
    'agentActivity[].kind',
    'agentActivity[].inputTokens',
    'agentActivity[].contextTokens',
    'agentActivity[].futureUnreviewedFact',
  ]) {
    const disposition = classifySidecarField(path)
    assert.equal(disposition?.classification, 'not-yet-captured', path)
  }
  assert.match(
    classifySidecarField('agentActivity[].captureOrdinal')?.reason ?? '',
    /path-only classification/,
    'the oracle must disclose that selected Activity semantics require a kind-aware fixture')
  for (const path of [
    'messages[].providerFrameUUID',
    'messages[].supersededByFrameUUID',
  ]) {
    assert.equal(classifySidecarField(path)?.classification, 'intentionally-omitted', path)
  }
})

test('reviewed capture surface is explicit, fail-closed, and pinned to its sources', () => {
  const audit = auditReviewedCaptureSurface()
  assert.deepEqual(audit.unclassified, [])
  // 265, plus the 11-field `compaction_summary` union, the correlation sequence on
  // `compact_boundary`, the workflow tool-observation correlation handle, and its query-attempt
  // accounting ordinal. None is canonical until root C maps the corresponding refinement fact.
  assert.equal(audit.classified.length, 279)
  const count = (classification) =>
    audit.classified.filter((item) => item.classification === classification).length
  assert.equal(count('canonical'), 176)
  assert.equal(count('derived-projection'), 4)
  // 77, plus 8 unmapped `compaction_summary` fields, the unmapped boundary sequence, and the
  // workflow tool-observation correlation handle and its query-attempt accounting ordinal.
  assert.equal(count('intentionally-omitted'), 88)
  // Stays zero on purpose. `not-yet-captured` describes persisted sidecar fields awaiting a
  // mapping; the C1.5 evidence invariant requires every reviewed capture-surface field to reach a
  // terminal disposition, so a wire event may never sit here.
  assert.equal(count('not-yet-captured'), 0)
  // Eight existing local fields plus summaryPath and the two provider handles.
  assert.equal(count('private-local'), 11)
  assert.equal(count('unknown'), 0)
  // 166, plus the 11-field summary union, the production-only boundary sequence, and the
  // two production workflow correlation fields. No fixture invokes PostCompact, so the summary is
  // reviewed without claiming baseline reachability.
  assert.equal(REVIEWED_CAPTURE_BASELINE_EXCLUSIONS.size, 180)
  const auditedKeys = new Set(audit.classified.map(reviewedCaptureFieldKey))
  for (const key of REVIEWED_CAPTURE_BASELINE_EXCLUSIONS) {
    assert.ok(auditedKeys.has(key), `${key}: baseline exclusion must name a reviewed field`)
  }
  // Deliberately unchanged: recall and PostCompact fields are excluded because no deterministic
  // fixture makes either provider surface fire. Baseline reachability must not appear to grow on
  // the strength of a reviewed surface no fixture reaches.
  assert.equal(audit.classified.length - REVIEWED_CAPTURE_BASELINE_EXCLUSIONS.size, 99)

  for (const eventType of [
    'turn_started', 'usage', 'error', 'steer_ack', 'steer_rejected',
  ]) {
    const fields = audit.classified.filter((item) => item.eventType === eventType)
    assert.ok(fields.length > 0, `${eventType}: field inventory must exercise lifecycle capture`)
    assert.ok(
      fields.every((item) => item.classification === 'canonical'),
      `${eventType}: no child field may hide behind a classified parent container`)
  }
  const workflow = audit.classified.filter((item) => item.eventType === 'workflow_update')
  assert.equal(workflow.filter((item) => item.classification === 'canonical').length, 47)
  assert.equal(workflow.filter((item) => item.classification === 'derived-projection').length, 2)
  assert.equal(
    workflow.filter((item) => item.classification === 'intentionally-omitted').length, 2)
  assert.equal(workflow.filter((item) => item.classification === 'not-yet-captured').length, 0)
  assert.equal(workflow.filter((item) => item.classification === 'private-local').length, 1)

  for (const [eventType, expectedCounts] of Object.entries({
    compaction_summary: { 'intentionally-omitted': 8, 'private-local': 3 },
    permission_request: { canonical: 9, 'intentionally-omitted': 3, 'private-local': 3 },
    permission_response_ack: { canonical: 4, 'intentionally-omitted': 3 },
    question_request: { canonical: 12, 'intentionally-omitted': 1 },
    question_response_ack: { canonical: 4, 'intentionally-omitted': 2 },
    interaction_closed: { canonical: 5, 'intentionally-omitted': 1 },
  })) {
    const fields = audit.classified.filter((item) => item.eventType === eventType)
    assert.equal(fields.length,
      Object.values(expectedCounts).reduce((total, value) => total + value, 0))
    for (const [classification, expected] of Object.entries(expectedCounts)) {
      assert.equal(fields.filter((item) => item.classification === classification).length,
        expected, `${eventType}.${classification}`)
    }
  }

  for (const [outboundType, expectedCounts] of Object.entries({
    steer: { canonical: 2, 'intentionally-omitted': 3 },
    permission_response: { canonical: 4, 'intentionally-omitted': 3 },
    question_response: { canonical: 3, 'intentionally-omitted': 3 },
    interrupt: { canonical: 1, 'intentionally-omitted': 2 },
  })) {
    assert.ok(Object.hasOwn(REVIEWED_CAPTURE_OUTBOUND_REQUEST_FIELDS, outboundType))
    const fields = audit.classified.filter((item) => item.outboundType === outboundType)
    assert.equal(fields.length,
      Object.values(expectedCounts).reduce((total, value) => total + value, 0))
    for (const [classification, expected] of Object.entries(expectedCounts)) {
      assert.equal(fields.filter((item) => item.classification === classification).length,
        expected, `outbound ${outboundType}.${classification}`)
    }
  }

  for (const path of [
    'producer', 'producer.name', 'producer.version', 'producer.build',
    'profile', 'profile.id', 'profile.version',
  ]) {
    assert.equal(classifyReviewedCaptureField(path)?.classification, 'canonical')
  }
  for (const [eventType, field, expected] of [
    ['workflow_update', 'status', 'canonical'],
    ['compact_boundary', 'compactionSequence', 'intentionally-omitted'],
    ['compaction_summary', 'summary', 'intentionally-omitted'],
    ['compaction_summary', 'summarySource', 'intentionally-omitted'],
    ['compaction_summary', 'summaryPath', 'private-local'],
    ['compaction_summary', 'sessionId', 'private-local'],
    ['compaction_summary', 'promptId', 'private-local'],
    ['tool_use', 'frameUUID', 'intentionally-omitted'],
    ['workflow_update', 'agentPath', 'canonical'],
    ['workflow_update', 'usage.toolUses', 'canonical'],
    ['workflow_update', 'workflowProgress[].agentId', 'canonical'],
    ['workflow_update', 'toolEventID', 'intentionally-omitted'],
    ['workflow_update', 'providerQuerySequence', 'intentionally-omitted'],
    ['workflow_update', 'outputFile', 'private-local'],
    ['ready', 'auth', 'intentionally-omitted'],
    ['ready', 'cwd', 'private-local'],
    ['permission_request', 'writeEscape', 'canonical'],
    ['permission_request', 'writeEscape.target', 'private-local'],
    ['permission_request', 'writeEscape.workspace', 'private-local'],
    ['permission_request', 'input.command', 'private-local'],
    ['permission_request', 'input.name', 'intentionally-omitted'],
    ['permission_request', 'capability.safety', 'canonical'],
    ['permission_request', 'permissionId', 'intentionally-omitted'],
    ['question_request', 'questions[].options[].preview', 'canonical'],
    ['question_request', 'reqId', 'intentionally-omitted'],
    ['permission_response_ack', 'allow', 'intentionally-omitted'],
    ['question_response_ack', 'responseId', 'intentionally-omitted'],
    ['interaction_closed', 'outcome', 'canonical'],
    ['interaction_closed', 'requestId', 'intentionally-omitted'],
  ]) {
    assert.equal(
      classifyReviewedCaptureField(`events[].event.${field}`, eventType)?.classification,
      expected,
      `${eventType}.${field}`)
  }
  for (const [outboundType, field, expected] of [
    ['steer', 'prompt', 'canonical'],
    ['steer', 'steerId', 'intentionally-omitted'],
    ['permission_response', 'allow', 'canonical'],
    ['permission_response', 'permissionId', 'intentionally-omitted'],
    ['permission_response', 'responseId', 'intentionally-omitted'],
    ['question_response', 'answers', 'canonical'],
    ['question_response', 'response', 'canonical'],
    ['question_response', 'reqId', 'intentionally-omitted'],
    ['interrupt', 'type', 'canonical'],
    ['interrupt', 'turnId', 'intentionally-omitted'],
  ]) {
    assert.equal(classifyReviewedCaptureField(
      `outboundRequests[].request.${field}`, null, outboundType)?.classification,
    expected, `outbound ${outboundType}.${field}`)
  }
  for (const [eventType, path] of [
    [null, 'producer.futureUnreviewedField'],
    ['workflow_update', 'events[].event.usage.futureUnreviewedMetric'],
    ['workflow_update', 'events[].event.workflowProgress[].futureUnreviewedField'],
    ['usage', 'events[].event.futureUnreviewedField'],
    ['future_event', 'events[].event.type'],
  ]) {
    assert.equal(
      classifyReviewedCaptureField(path, eventType), null,
      `${eventType ?? 'envelope'}:${path} must fail closed until reviewed`)
  }
  for (const [outboundType, path] of [
    ['permission_response', 'outboundRequests[].request.prompt'],
    ['permission_response', 'outboundRequests[].request.futureUnreviewedField'],
    ['question_response', 'outboundRequests[].request.answers.futureProtocolMember'],
    ['future_request', 'outboundRequests[].request.type'],
  ]) {
    assert.equal(classifyReviewedCaptureField(path, null, outboundType), null,
      `outbound ${outboundType}:${path} must fail closed until reviewed`)
  }
  assert.notEqual(
    reviewedCaptureFieldKey({
      eventType: 'permission_request', path: 'events[].event.type',
    }),
    reviewedCaptureFieldKey({
      outboundType: 'permission_request', path: 'events[].event.type',
    }),
    'baseline keys must distinguish inbound events from outbound requests')
  const resumeHandle = audit.classified.find(
    (item) => item.eventType === 'session' && item.path.endsWith('.sessionId'))
  assert.equal(resumeHandle.classification, 'private-local')

  assert.ok(Object.hasOwn(REVIEWED_CAPTURE_SOURCE_PINS, 'agentd/src/agentd.mjs'))
  assert.ok(Object.hasOwn(
    REVIEWED_CAPTURE_SOURCE_PINS, 'agentd/src/claude-compaction-summary.mjs'))
  assert.ok(Object.hasOwn(
    REVIEWED_CAPTURE_SOURCE_PINS, 'agentd/src/claude-message-events.mjs'))
  assert.ok(Object.hasOwn(REVIEWED_CAPTURE_SOURCE_PINS, 'agentd/src/codex-workflows.mjs'))
  assert.ok(Object.hasOwn(REVIEWED_CAPTURE_SOURCE_PINS, 'agentd/src/tool-surface.mjs'))
  assert.ok(Object.hasOwn(
    REVIEWED_CAPTURE_SOURCE_PINS, 'agentd/src/harness-observations.mjs'))
  assert.ok(Object.hasOwn(
    REVIEWED_CAPTURE_SOURCE_PINS, 'agentd/src/otel-metrics-receiver.mjs'))
  assert.deepEqual(REVIEWED_CAPTURE_EVENT_FIELDS.compaction_summary, [
    'type', 'id', 'trigger', 'compactionSequence', 'summary', 'summarySource',
    'summaryTruncated', 'summaryBytes', 'summaryPath', 'sessionId', 'promptId',
  ])
  for (const [relativePath, expected] of Object.entries(REVIEWED_CAPTURE_SOURCE_PINS)) {
    const actual = crypto.createHash('sha256')
      .update(fs.readFileSync(path.join(repo, relativePath))).digest('hex')
    assert.equal(actual, expected, `${relativePath}: capture-source drift requires field re-audit`)
  }
})

test('workflow fixture exercises the reviewed wire surface and terminal monotonicity', async () => {
  const fixture = path.join(
    repo, 'agentd/test/fixtures/format-review-workflow-lifecycle-fixture.mjs')
  const capture = await captureTurn(fixture, {
    prompt: 'exercise workflow fields', requireQuiescence: true,
    observedAtForSequence: (sequence) =>
      new Date(Date.UTC(2026, 7, 3, 18, 0, sequence)).toISOString(),
  })
  const updates = capture.events
    .filter(({ event }) => event.type === 'workflow_update')
    .map(({ event }) => event)
  const observed = new Set()
  const visit = (node, prefix = '') => {
    if (Array.isArray(node)) {
      observed.add(`${prefix}[]`)
      for (const item of node) visit(item, `${prefix}[]`)
      return
    }
    if (!node || typeof node !== 'object') return
    for (const [key, value] of Object.entries(node)) {
      const path = prefix ? `${prefix}.${key}` : key
      observed.add(path)
      visit(value, path)
    }
  }
  for (const update of updates) visit(update)
  assert.deepEqual(
    REVIEWED_CAPTURE_PRODUCTION_SOURCE_FIELDS.filter((field) => !observed.has(field)), [])

  const aggregate = updates.filter((event) => event.taskId === 'workflow-task')
  assert.ok(aggregate.length >= 4, 'the cumulative workflow snapshot must repeat')
  assert.equal(aggregate[0].workflowProgress[0].type, 'workflow_phase')
  assert.equal(aggregate[1].workflowProgress[0].type, 'workflow_agent')
  assert.equal(aggregate.at(-1).workflowProgress[0].state, 'progress')
  assert.equal(capture.quiescence.root.type, 'done')
  assert.deepEqual(capture.quiescence.children, [{
    id: 'parent-task', parentId: null, state: 'completed',
    stateHistory: ['running', 'completed'],
  }, {
    id: 'workflow-task', parentId: 'parent-task', state: 'failed',
    stateHistory: ['running', 'failed'],
  }])
  assert.equal(
    classifyReviewedCaptureField(
      'events[].event.workflowProgress[].futureUnreviewedField', 'workflow_update'),
    null)
})

test('exact comparator catches leaf mutation and rejects non-JSON values', () => {
  const canonical = {
    format: 'mechanician-canonical-graph/0-spike', sessionIds: [],
    agents: [{ id: 'root', parentId: null, type: 'root', task: null }],
    events: [{ kind: 'assistant_message', agentId: 'root', text: 'alpha' }],
  }
  const changed = structuredClone(canonical)
  changed.events[0].text = 'bravo'
  assert.deepEqual(compareCanonicalFields(canonical, canonical), [])
  assert.deepEqual(compareCanonicalFields(canonical, changed).map((item) => item.path), [
    'events[0].text',
  ])
  assert.notEqual(canonicalDigest(canonical), canonicalDigest(changed))

  assert.throws(() => canonicalDigest({ value: undefined }), /not JSON/)
  assert.throws(() => canonicalDigest({ value: Number.POSITIVE_INFINITY }), /not JSON/)
  assert.throws(() => canonicalDigest({ value: new Date() }), /non-plain object/)
  const sparse = []
  sparse.length = 1
  assert.throws(() => canonicalDigest({ sparse }), /sparse arrays/)
})

test('minimal one-turn seed is deterministic with producer/profile metadata', async () => {
  const fixture = path.join(repo, 'agentd/test/fixtures/minimal-conversation-fixture.mjs')
  const options = {
    prompt: 'Minimal retained prompt.',
    observedAtForSequence: (sequence) =>
      new Date(Date.UTC(2026, 7, 2, 12, 0, sequence)).toISOString(),
  }
  const first = await runComparison(fixture, options)
  const second = await runComparison(fixture, options)
  assert.deepEqual(first.canonical, second.canonical)
  assert.equal(
    canonicalDigest(first.canonical),
    '56e34f36ab0981d6ad0b6a28190e335a85362d32487a7c8e1c195be583956a94')
  assert.equal(canonicalDigest(first.canonical), canonicalDigest(second.canonical))
  assert.deepEqual(first.canonical.producer, {
    name: 'Mechanician R2 capture harness', version: '0.23.0', build: '207',
  })
  assert.deepEqual(first.canonical.profile, {
    id: 'ai.mechanician.conversation-record.native-graph', version: '0-spike',
  })
  assert.ok(!JSON.stringify(first.canonical).includes('PRIVATE-RESUME-HANDLE'))

  for (const root of Object.keys(first.results.roots)) {
    assert.equal(first.results.roots[root].digest, second.results.roots[root].digest)
    assert.deepEqual(first.results.roots[root].unclassifiedDifferences, [])
  }
  assert.equal(
    first.results.roots['A:vcon+agent_session'].digest,
    '2644579c87d982ce3271e8dbd61f50b011a04a3f17ac669da745a288236e41d5')
  assert.equal(
    first.results.roots['B:acr-vac'].digest,
    '2644579c87d982ce3271e8dbd61f50b011a04a3f17ac669da745a288236e41d5')
  assert.equal(
    first.results.roots['C:canonical-graph'].digest,
    '56e34f36ab0981d6ad0b6a28190e335a85362d32487a7c8e1c195be583956a94')
})

test('lifecycle evidence pins success, provider-error, and interruption digests', async () => {
  const fixture = path.join(repo, 'agentd/test/fixtures/format-review-lifecycle-fixture.mjs')
  const observedAtForSequence = (sequence) =>
    new Date(Date.UTC(2026, 7, 3, 12, 0, sequence)).toISOString()
  const success = await runComparison(fixture, {
    prompt: 'success', promptObservedAt: '2026-08-03T11:59:59.000Z',
    observedAtForSequence, requireQuiescence: true,
    steeringRequests: [{
      steerId: 'steer-accepted', prompt: 'Please include the accepted steering fact.',
    }, {
      steerId: 'steer-rejected', prompt: 'This request is rejected by the fixture.',
    }],
  })
  const providerError = await runComparison(fixture, {
    prompt: 'error', observedAtForSequence, requireQuiescence: true,
  })
  const interrupted = await runComparison(fixture, {
    prompt: 'interrupted', observedAtForSequence, requireQuiescence: true,
  })

  assert.equal(
    canonicalDigest(success.canonical),
    'eeeaef8eea22d37ed4f21e95f6efa7010078dc6fcf7bed1fe99d64e11b78c236')
  assert.equal(
    canonicalDigest(providerError.canonical),
    '3432c5b90693ab652aeafa91bc10938443be110ce6df2838c4cfe50a88a37a06')
  assert.equal(
    canonicalDigest(interrupted.canonical),
    '9a64cd9a74196dca26c52619c0bef5950e0594e7076ff58d5d40fc613b2607a6')

  for (const [run, expectedDifferences] of [
    [success, 53], [providerError, 11], [interrupted, 6],
  ]) {
    for (const root of ['A:vcon+agent_session', 'B:acr-vac']) {
      assert.equal(run.results.roots[root].differences.length, expectedDifferences)
      assert.equal(run.results.roots[root].declaredPrototypeGaps.length, expectedDifferences)
      assert.deepEqual(run.results.roots[root].unclassifiedDifferences, [])
    }
    assert.deepEqual(run.results.roots['C:canonical-graph'].differences, [])
  }
})
