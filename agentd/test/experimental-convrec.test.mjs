import test from 'node:test'
import assert from 'node:assert/strict'
import crypto from 'node:crypto'

import {
  PRELUDE,
  PROFILE_LOCAL_FULL,
  PROFILE_SHARE_SNAPSHOT,
  applyExperimentalDisclosureProfile,
  crc32,
  encodeExperimentalConversationRecord,
} from '../src/convrec/experimental-binding.mjs'

const source = () => ({
  id: '11111111-2222-4333-8444-555555555555',
  title: 'Experimental export PRIVATE_RESUME_HANDLE',
  titleSource: 'manual',
  cwd: '/tmp/x',
  sdkSessionId: 'PRIVATE_RESUME_HANDLE',
  queuedPrompts: ['PRIVATE_QUEUE'],
  pendingTurnPrompt: 'PRIVATE_PENDING',
  draft: 'PRIVATE_DRAFT',
  providerAccessRequest: { id: 'PRIVATE_ACCESS_REQUEST_ID' },
  projectID: '99999999-8888-4777-8666-555555555555',
  updatedAt: '2026-08-03T10:00:00.000Z',
  futurePrivateField: 'PRIVATE_FUTURE_VALUE',
  workflowRuns: {
    'PRIVATE_RUN_KEY': {
      runKey: 'PRIVATE_RUN_KEY', workflowName: 'PRIVATE_WORKFLOW_NAME',
      description: 'PRIVATE_DESCRIPTION', summary: 'PRIVATE_SUMMARY',
      phases: { p1: { index: 1, title: 'PRIVATE_PHASE_TITLE' } },
      agents: {
        worker: {
          index: 1, phaseIndex: 1, phaseTitle: 'PRIVATE_PHASE_TITLE',
          label: 'PRIVATE_LABEL', promptPreview: 'PRIVATE_PROMPT_PREVIEW',
          lastToolName: 'PRIVATE_TOOL_NAME', lastToolSummary: 'PRIVATE_ACTIVITY_SUMMARY',
          resultPreview: 'PRIVATE_RESULT_PREVIEW', state: 'done',
        },
      },
    },
  },
  messages: [
    {
      id: 'AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE', kind: 'user',
      text: 'Read /Users/private/project/source.swift', captureOrdinal: 1,
    },
    {
      id: 'BBBBBBBB-CCCC-4DDD-8EEE-FFFFFFFFFFFF', kind: 'tool',
      text: 'PRIVATE_TOOL_INPUT in /tmp/x before PRIVATE_RESUME_HANDLE and PRIVATE_ACCESS_REQUEST_ID after',
      toolUseId: 'provider-tool-PRIVATE',
      toolResult: 'PRIVATE_TOOL_RESULT before PRIVATE_RESUME_HANDLE after',
      captureOrdinal: 2, toolResultCaptureOrdinal: 3,
    },
    {
      id: 'CCCCCCCC-DDDD-4EEE-8FFF-000000000000', kind: 'assistant',
      text: 'Done.', captureOrdinal: 4,
    },
    {
      id: 'DDDDDDDD-EEEE-4FFF-8000-111111111111', kind: 'question',
      questionDecided: true,
      questionAnswers: { PRIVATE_RESUME_HANDLE: 'selected' },
      captureOrdinal: 5, interactionResponseCaptureOrdinal: 6,
    },
  ],
})

function independentlyScan(bytes) {
  assert.deepEqual(bytes.subarray(0, PRELUDE.length), PRELUDE)
  const frames = []
  let offset = PRELUDE.length
  while (offset < bytes.length) {
    const frameStart = offset
    assert.ok(offset + 8 <= bytes.length)
    const length = bytes.readUInt32LE(offset)
    const expectedCRC = bytes.readUInt32LE(offset + 4)
    offset += 8
    assert.ok(offset + length <= bytes.length)
    const payload = bytes.subarray(offset, offset + length)
    assert.equal(crc32(payload), expectedCRC)
    offset += length
    frames.push({ frameStart, object: JSON.parse(payload.toString('utf8')) })
  }
  return frames
}

test('experimental local-full record commits exact framed bytes and remints source identities', () => {
  const encoded = encodeExperimentalConversationRecord({
    sidecar: source(), profile: PROFILE_LOCAL_FULL,
    producer: { version: '0.23.0', build: '207', sourceRevision: 'test' },
  })
  const frames = independentlyScan(encoded.bytes)
  const commit = frames.at(-1)
  const raw = encoded.bytes.toString('utf8')

  assert.equal(frames[0].object.frameType, 'manifest')
  assert.equal(frames[1].object.frameType, 'graph')
  assert.equal(frames.slice(2, -1).every((frame) => frame.object.frameType === 'event'), true)
  assert.equal(frames.slice(2, -1).length, 7)
  assert.equal(commit.object.frameType, 'commit')
  assert.equal(commit.object.committedFrameCount, frames.length - 1)
  assert.equal(commit.object.committedByteLength, commit.frameStart)
  assert.equal(commit.object.contentDigestSHA256,
    crypto.createHash('sha256').update(encoded.bytes.subarray(0, commit.frameStart)).digest('hex'))
  assert.match(encoded.report.lineageID, /^urn:uuid:[0-9a-f-]{14}8[0-9a-f-]+$/)
  assert.notEqual(encoded.report.lineageID, encoded.report.versionID)
  assert.match(raw,
    /PRIVATE_TOOL_INPUT in \[private operative value omitted\] before \[private operative value omitted\] and \[private operative value omitted\] after/)
  assert.match(raw, /PRIVATE_TOOL_RESULT before \[private operative value omitted\] after/)
  assert.match(raw, /Experimental export \[private operative value omitted\]/)
  assert.ok(encoded.report.omissions.some(
    (item) => item.code === 'private-operative-value-echoes' && item.count >= 1))
  for (const forbidden of [
    '/tmp/x', 'PRIVATE_RESUME_HANDLE', 'PRIVATE_QUEUE', 'PRIVATE_PENDING',
    'PRIVATE_DRAFT', 'PRIVATE_ACCESS_REQUEST_ID', 'PRIVATE_FUTURE_VALUE', 'provider-tool-PRIVATE',
    '11111111-2222-4333-8444-555555555555',
    'AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE',
  ]) assert.doesNotMatch(raw, new RegExp(forbidden))
})

test('share snapshot keeps dialog but removes sensitive tool and path content', () => {
  const encoded = encodeExperimentalConversationRecord({
    sidecar: source(), profile: PROFILE_SHARE_SNAPSHOT,
  })
  const frames = independentlyScan(encoded.bytes)
  const graph = frames[1].object.graph
  const raw = encoded.bytes.toString('utf8')

  assert.equal(encoded.report.events, 3)
  assert.equal(graph.chronology.eventCount, encoded.report.events)
  assert.equal(graph.chronology.capturedOrdinalEventCount, 2)
  assert.equal(graph.chronology.missingCaptureOrdinalEventCount, 1)
  assert.equal(graph.chronology.maximumCaptureOrdinal, 4)
  assert.equal(graph.chronology.captureBatchCount, 2)
  assert.match(raw, /Read \[absolute path omitted\]/)
  assert.match(raw, /Done\./)
  assert.doesNotMatch(raw, /PRIVATE_TOOL_INPUT|PRIVATE_TOOL_RESULT|provider-tool-PRIVATE/)
  for (const sensitive of [
    'PRIVATE_WORKFLOW_NAME', 'PRIVATE_DESCRIPTION', 'PRIVATE_SUMMARY', 'PRIVATE_PHASE_TITLE',
    'PRIVATE_LABEL', 'PRIVATE_PROMPT_PREVIEW', 'PRIVATE_TOOL_NAME',
    'PRIVATE_ACTIVITY_SUMMARY', 'PRIVATE_RESULT_PREVIEW', 'Experimental export',
  ]) assert.doesNotMatch(raw, new RegExp(sensitive))
  assert.match(raw, /Shared Conversation/)
  assert.ok(encoded.report.omissions.some(
    (item) => item.code === 'share-sensitive-event-content' && item.count === 4))
  assert.ok(encoded.report.omissions.some(
    (item) => item.code === 'private-drafts-queues-and-waits' && item.count === 4))
})

test('share snapshot fails closed when a future canonical field appears', () => {
  const projected = applyExperimentalDisclosureProfile({
    format: 'ai.mechanician.conversation-record/0-experimental',
    sessionIds: [],
    agents: [{ id: 'root', parentId: null, type: 'root', futureSecret: 'PRIVATE_ACTOR' }],
    chronology: { status: 'complete', eventCount: 1, futureSecret: 'PRIVATE_CHRONOLOGY' },
    events: [
      {
        kind: 'assistant_message', eventId: 'event-1', agentId: 'root',
        text: 'Public dialog', futureSecret: 'PRIVATE_EVENT',
      },
      {
        kind: 'agent_lifecycle', eventId: 'event-2', agentId: 'root',
        state: 'completed', text: 'PRIVATE_CONTEXTUAL_TEXT',
      },
    ],
    futureSecret: 'PRIVATE_GRAPH',
  }, PROFILE_SHARE_SNAPSHOT)
  const raw = JSON.stringify(projected.canonical)

  assert.match(raw, /Public dialog/)
  assert.doesNotMatch(
    raw,
    /PRIVATE_ACTOR|PRIVATE_CHRONOLOGY|PRIVATE_EVENT|PRIVATE_GRAPH|PRIVATE_CONTEXTUAL_TEXT/)
  assert.ok(projected.omissions.some(
    (item) => item.code === 'share-non-dialog-content-fields' && item.count >= 5))
  assert.equal(Object.hasOwn(projected.canonical, 'sessionIds'), false)
  assert.equal(projected.canonical.chronology.eventCount, projected.canonical.events.length)
  assert.equal(projected.canonical.chronology.captureBatchCount, 0)
})
