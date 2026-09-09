import test from 'node:test'
import assert from 'node:assert/strict'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { captureTurn } from '../capture.mjs'
import { toCanonical } from '../canonical.mjs'
import { runComparison } from '../run.mjs'
import { canonicalDigest } from '../canonical-field-contract.mjs'
import {
  interactionCaptureOptions, interactionObservedAtForSequence,
} from '../interaction-fixture-plan.mjs'

const repo = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', '..')
const fixture = path.join(
  repo, 'agentd', 'test', 'fixtures', 'format-review-interaction-lifecycle-fixture.mjs')
const observedAtForSequence = interactionObservedAtForSequence
const captureOptions = interactionCaptureOptions()

test('capture proves interaction, failure, replay, and interruption lifecycle to quiescence', async () => {
  const capture = await captureTurn(fixture, captureOptions)
  assert.deepEqual(capture.quiescence.children.map(({ id, state }) => [id, state]), [
    ['child-failed', 'failed'], ['child-stopped', 'stopped'],
  ])
  assert.deepEqual(capture.outboundRequests.map(({ request }) => request.type), [
    'permission_response', 'permission_response', 'permission_response',
    'question_response', 'interrupt',
  ])

  const canonical = toCanonical(capture)
  const portable = JSON.stringify(canonical)
  for (const privateOrOperative of [
    '/Users/private/Outside/result.txt', '/Users/private/Workspace',
    '/Users/private/OrdinaryPermission/secret.txt',
    'permission-write-escape', 'permission-capability', 'write-response-1',
    'capability-response-1', 'question-output-style', 'question-response-1',
    'interrupt-root-1',
  ]) {
    assert.doesNotMatch(portable, new RegExp(privateOrOperative.replaceAll('/', '\\/')))
  }

  const authorizations = canonical.events.filter(
    (event) => event.kind.startsWith('authorization_'))
  const requests = authorizations.filter((event) => event.kind === 'authorization_request')
  const responses = authorizations.filter((event) => event.kind === 'authorization_response')
  const acknowledgements = authorizations.filter((event) => event.kind === 'authorization_ack')
  assert.deepEqual(requests.map((event) => event.interactionId), [
    'authorization-1', 'authorization-2',
  ])
  assert.equal(requests[0].input, null)
  assert.equal(requests[0].inputDisclosure, 'omitted-private-operative-input')
  assert.deepEqual(requests[0].boundaryRequest, {
    kind: 'workspace-escape', locatorDisclosure: 'omitted-private-local',
  })
  assert.equal(requests[1].input, null)
  assert.equal(requests[1].inputDisclosure, 'omitted-private-operative-input')
  assert.equal(requests[1].capability.safety, 'sensitive')
  assert.deepEqual(responses.map((event) => [
    event.interactionId, event.decision, event.requestedScope, event.deliveryAttempts,
  ]), [
    ['authorization-1', 'allow', 'once', 2],
    ['authorization-2', 'deny', 'once', 1],
  ])
  assert.ok(responses.every((event) => event.operativeGrantIncluded === false))
  assert.deepEqual(acknowledgements.map((event) => [
    event.interactionId, event.accepted,
  ]), [
    ['authorization-1', true], ['authorization-1', true],
    ['authorization-2', true],
  ], 'exact replay keeps one decision while retaining both cached acknowledgements')

  const question = canonical.events.find((event) => event.kind === 'question')
  const answer = canonical.events.find((event) => event.kind === 'answer')
  const answerAck = canonical.events.find((event) => event.kind === 'answer_ack')
  assert.equal(question.interactionId, 'question-1')
  assert.equal(answer.interactionId, question.interactionId)
  assert.equal(answerAck.interactionId, question.interactionId)
  assert.equal(answer.answers['Which output style should the fixture retain?'], 'Detailed')

  const failedTool = canonical.events.find(
    (event) => event.kind === 'tool_result' && event.outcome === 'failed')
  assert.equal(failedTool.isError, true)
  assert.equal(failedTool.status, 'error')
  assert.equal(canonical.events.find(
    (event) => event.kind === 'agent_lifecycle' && event.state === 'failed').outcome, 'failed')
  assert.equal(canonical.events.find(
    (event) => event.kind === 'agent_lifecycle' && event.state === 'stopped').outcome, 'stopped')

  const interruptionIndex = canonical.events.findIndex(
    (event) => event.kind === 'interruption_requested')
  const stoppedIndex = canonical.events.findIndex((event) => event.kind === 'turn_stopped')
  assert.ok(interruptionIndex >= 0 && stoppedIndex > interruptionIndex)
  assert.equal(canonical.events.some((event) => event.kind === 'turn_completed'), false)
  assert.equal(canonical.events.some((event) => 'retryOf' in event), false,
    'the current wire has no retry relationship to preserve or fabricate')
})

test('all three semantic roots preserve the interaction skeleton without silent loss', async () => {
  const run = await runComparison(fixture, captureOptions)
  assert.equal(canonicalDigest(run.canonical),
    '59e35a868bb7c057e2367daa7c51db19e76342c5daca6482d0a251f1c866c685')
  for (const result of Object.values(run.results.roots)) {
    assert.deepEqual(result.structuralMisses, [])
    assert.deepEqual(result.unclassifiedDifferences, [])
  }
  for (const root of ['A:vcon+agent_session', 'B:acr-vac']) {
    assert.ok(run.results.roots[root].extensions.some(
      (entry) => entry.includes('authorization request')))
    assert.ok(run.results.roots[root].extensions.some(
      (entry) => entry.includes('question request')))
  }
})

test('interrupt closes pending permissions and questions without fabricating responses', async () => {
  for (const plan of [{
    prompt: 'pending-permission', interactionKind: 'permission',
    requestField: 'permissionId', requestId: 'permission-left-pending',
    canonicalType: 'authorization', requestKind: 'authorization_request',
  }, {
    prompt: 'pending-question', interactionKind: 'question',
    requestField: 'reqId', requestId: 'question-left-pending',
    canonicalType: 'question', requestKind: 'question',
  }]) {
    const pendingOptions = {
      prompt: plan.prompt, observedAtForSequence, requireQuiescence: true,
      interruptRequests: [{
        id: `interrupt-${plan.interactionKind}`,
        after: { type: `${plan.interactionKind}_request`, [plan.requestField]: plan.requestId },
      }],
    }
    const capture = await captureTurn(fixture, pendingOptions)
    const eventTypes = capture.events.map(({ event }) => event.type)
    const closureIndex = eventTypes.indexOf('interaction_closed')
    const doneIndex = eventTypes.indexOf('done')
    assert.ok(closureIndex > eventTypes.indexOf(`${plan.interactionKind}_request`))
    assert.ok(doneIndex > closureIndex, 'closure must precede the turn terminal')
    assert.deepEqual(capture.outboundRequests.map(({ request }) => request.type), ['interrupt'])
    assert.equal(capture.quiescence.root.interrupted, true)

    const canonical = toCanonical(capture)
    const closure = canonical.events.find((event) => event.kind === 'interaction_closed')
    const request = canonical.events.find((event) => event.kind === plan.requestKind)
    assert.deepEqual([
      closure.interactionId, closure.interactionType, closure.outcome, closure.reason,
    ], [request.interactionId, plan.canonicalType, 'cancelled', 'turn_interrupted'])
    assert.equal(canonical.events.some((event) =>
      ['authorization_response', 'answer'].includes(event.kind)), false,
    'Stop is not a Deny and does not invent an answer')
    assert.doesNotMatch(JSON.stringify(canonical), new RegExp(plan.requestId))

    const comparison = await runComparison(fixture, pendingOptions)
    for (const result of Object.values(comparison.results.roots)) {
      assert.deepEqual(result.structuralMisses, [])
      assert.deepEqual(result.unclassifiedDifferences, [])
    }
  }
})

test('capture still refuses quiescence with a delivered but unacknowledged response', async () => {
  await assert.rejects(
    captureTurn(fixture, {
      prompt: 'unacked-permission', observedAtForSequence, requireQuiescence: true,
      permissionResponses: [{
        permissionId: 'permission-unacknowledged', responseId: 'unacked-response',
        allow: true, always: false,
      }],
    }),
    /pending interactions: permission permission-unacknowledged, permission response unacked-response/)
})

test('response-id collisions and unmatched plans fail closed', async () => {
  assert.throws(() => captureTurn(fixture, {
    permissionResponses: [{
      permissionId: 'first', responseId: 'collision', allow: true, always: false,
    }, {
      permissionId: 'second', responseId: 'collision', allow: false, always: false,
    }],
  }), /permission response id collision/)
  assert.throws(() => captureTurn(fixture, {
    permissionResponses: [{
      permissionId: 'same-request', responseId: 'first-response',
      allow: true, always: false,
    }, {
      permissionId: 'same-request', responseId: 'second-response',
      allow: true, always: false,
    }],
  }), /permission same-request must reuse stable response id first-response/)

  await assert.rejects(captureTurn(fixture, {
    prompt: 'pending-permission', observedAtForSequence, requireQuiescence: false,
    permissionResponses: [{
      permissionId: 'never-emitted', responseId: 'never-sent', allow: true, always: false,
    }],
  }), /unmatched interaction plans: permission never-emitted\/never-sent/)
})

test('portable interaction identities separate request, response, and interaction families', () => {
  const at = '2026-08-03T18:00:00.000Z'
  const capture = {
    prompt: 'namespace collision', promptObservedAt: at,
    producer: { name: 'test', version: '1', build: '1' },
    profile: { id: 'test', version: '1' },
    events: [{
      seq: 1, observedAt: at, event: { type: 'turn_started', id: 'turn' },
    }, {
      seq: 2, observedAt: at,
      event: { type: 'permission_request', id: 'turn', permissionId: 'shared', name: 'Bash' },
    }, {
      seq: 3, observedAt: at,
      event: {
        type: 'permission_response_ack', id: 'turn', permissionId: 'shared-response',
        accepted: true,
      },
    }, {
      seq: 4, observedAt: at,
      event: { type: 'question_request', id: 'turn', reqId: 'shared', questions: [] },
    }, {
      seq: 5, observedAt: at,
      event: {
        type: 'question_response_ack', id: 'turn', reqId: 'shared',
        responseId: 'shared-response', accepted: true,
      },
    }, {
      seq: 6, observedAt: at, event: { type: 'done', id: 'turn' },
    }],
    outboundRequests: [{
      afterEventSequence: 2, observedAt: at,
      request: {
        type: 'permission_response', id: 'turn', permissionId: 'shared',
        responseId: 'shared-response', allow: true, always: false,
      },
    }, {
      afterEventSequence: 4, observedAt: at,
      request: {
        type: 'question_response', id: 'turn', reqId: 'shared',
        responseId: 'shared-response', answers: {},
      },
    }],
    quiescence: null,
  }
  const canonical = toCanonical(capture)
  const authorizationIDs = new Set(canonical.events
    .filter((event) => event.kind.startsWith('authorization_'))
    .map((event) => event.interactionId))
  const questionIDs = new Set(canonical.events
    .filter((event) => ['question', 'answer', 'answer_ack'].includes(event.kind))
    .map((event) => event.interactionId))
  assert.deepEqual([...authorizationIDs], ['authorization-1'])
  assert.deepEqual([...questionIDs], ['question-1'])
  assert.doesNotMatch(JSON.stringify(canonical), /shared(?:-response)?/)

  const collision = structuredClone(capture)
  collision.events.splice(3, 3, {
    seq: 4, observedAt: at,
    event: { type: 'permission_request', id: 'turn', permissionId: 'second', name: 'Read' },
  }, {
    seq: 5, observedAt: at,
    event: { type: 'done', id: 'turn' },
  })
  collision.outboundRequests[1] = {
    afterEventSequence: 4, observedAt: at,
    request: {
      type: 'permission_response', id: 'turn', permissionId: 'second',
      responseId: 'shared-response', allow: false, always: false,
    },
  }
  assert.throws(() => toCanonical(collision), /one authorization response id named two requests/)
})
