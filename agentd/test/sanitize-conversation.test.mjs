import test from 'node:test'
import assert from 'node:assert/strict'
import { execFileSync, spawnSync } from 'node:child_process'
import { fileURLToPath } from 'node:url'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'

const script = path.join(
  path.dirname(fileURLToPath(import.meta.url)), '..', 'scripts', 'sanitize-conversation.mjs')

const SECRET_TITLE = 'Fix the Northwind tenant probe'
const SECRET_TEXT = 'my apikey sk-SUPERSECRET lives in ~/dev/mechanician/agentd/.env'
const SECRET_TOOL = 'notarization ticket 7F2A accepted for Mechanician.app at /Users/testuser'

const sample = () => ({
  id: '11111111-2222-3333-4444-555555555555',
  title: SECRET_TITLE,
  cwd: '/Users/testuser/dev/mechanician',
  updatedAt: '2026-08-02T10:00:00.000Z',
  forkProvenance: {
    kind: 'assistantResponse',
    sourceConversationID: '12345678-1234-4234-A234-1234567890AB',
    sourceTitleSnapshot: 'A SECRET source conversation',
    forkPointEntryID: 'AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE',
    createdAt: '2026-08-02T09:59:00.000Z',
  },
  captureOrdinalHighWatermark: 12,
  sdkSessionId: 'claude:resume-handle-SECRET',
  draft: 'an unsent SECRET draft',
  queuedPrompts: ['queued SECRET work'],
  projectID: '99999999-8888-7777-6666-555555555555',
  messages: [
    {
      id: 'AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE',
      kind: 'user',
      text: SECRET_TEXT,
      observedAt: '2026-08-02T10:00:05.000Z',
      captureOrdinal: 1,
    },
    {
      id: 'FFFFFFFF-0000-1111-2222-333333333333',
      kind: 'tool',
      text: 'Bash',
      toolName: 'Bash',
      toolResult: SECRET_TOOL,
      toolUseId: 'toolu_SECRET_01',
      providerFrameUUID: 'provider-frame_SECRET_01',
      supersededByFrameUUID: 'provider-notice_SECRET_01',
      observedAt: '2026-08-02T10:01:05.000Z',
      captureOrdinal: 2,
      toolResultCaptureOrdinal: 3,
      toolTerminalCaptureOrdinal: 4,
      supersessionEventID: 'supersession_SECRET_01',
      supersededByEntryID: 'AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE',
      supersessionCaptureOrdinal: 5,
      interactionResponseStatus: 'selected',
      interactionResponseObservedAt: '2026-08-02T10:01:06.000Z',
      interactionAcknowledgedAt: '2026-08-02T10:01:07.000Z',
      interactionResponseCaptureOrdinal: 6,
      interactionAcknowledgedCaptureOrdinal: 7,
      interactionClosure: {
        outcome: 'cancelled', reason: 'turn_interrupted',
        observedAt: '2026-08-02T10:01:08.000Z',
        captureOrdinal: 8,
      },
      questionFreeTextResponse: 'SECRET free form answer',
      aBrandNewFieldFromAFutureBuild: 'must never leak',
    },
  ],
  subagents: {
    'toolu_SECRET_01': {
      key: 'toolu_SECRET_01',
      subagentType: 'Explore',
      task: 'read the SECRET config',
      status: 'stopped',
      startedCaptureOrdinal: 9,
      endedCaptureOrdinal: 10,
    },
  },
  agentActivity: [{
    id: 'activity_SECRET_01', kind: 'tool', phase: 'completed', agentID: 'root',
    at: '2026-08-02T10:01:09.000Z', captureOrdinal: 11,
    aBrandNewActivityFieldFromAFutureBuild: 'must never leak either',
  }],
})

const run = (input, seed) => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'sanitize-'))
  const file = path.join(dir, 'in.json')
  fs.writeFileSync(file, JSON.stringify(input))
  let stderr = ''
  const stdout = execFileSync(process.execPath, [script, '--seed', seed, file], {
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'pipe'],
  })
  try { stderr = fs.readFileSync(path.join(dir, 'unused'), 'utf8') } catch { /* stderr below */ }
  fs.rmSync(dir, { recursive: true, force: true })
  return { output: JSON.parse(stdout), raw: stdout, stderr }
}

const runWithProvenance = (input, seed) => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'sanitize-'))
  const file = path.join(dir, 'in.json')
  const out = path.join(dir, 'out.json')
  fs.writeFileSync(file, JSON.stringify(input))
  const result = spawnSync(
    process.execPath, [script, '--seed', seed, file, '--out', out], { encoding: 'utf8' })
  assert.equal(result.status, 0, result.stderr)
  const output = JSON.parse(fs.readFileSync(out, 'utf8'))
  fs.rmSync(dir, { recursive: true, force: true })
  return { output, provenance: JSON.parse(result.stderr) }
}

test('no free text, secret field, or real id survives sanitization', () => {
  const { raw, output } = run(sample(), 'seed-one')
  const secretWords = [SECRET_TITLE, SECRET_TEXT, SECRET_TOOL]
    .flatMap((s) => s.split(/\s+/))
    .filter((w) => w.length >= 5)
  for (const word of secretWords) {
    assert.ok(!raw.includes(word), `leaked free-text token: ${word}`)
  }
  assert.ok(!raw.includes('SECRET'), 'no marked value may survive in any field class')
  assert.ok(!raw.includes('testuser'), 'paths must be fully replaced')
  assert.ok(!raw.includes('11111111-2222'), 'real ids must be pseudonymized')
  assert.equal(output.sdkSessionId, undefined)
  assert.equal(output.draft, undefined)
  assert.equal(output.queuedPrompts, undefined)
  assert.equal(output.projectID, undefined)
  assert.equal(output.forkProvenance.kind, 'assistantResponse')
  assert.notEqual(
    output.forkProvenance.sourceConversationID,
    '12345678-1234-4234-A234-1234567890AB')
  assert.notEqual(output.forkProvenance.sourceTitleSnapshot, 'A SECRET source conversation')
  assert.equal(
    output.forkProvenance.forkPointEntryID,
    output.messages[0].id,
    'fork-point identity must correlate through the same pseudonym map')
  // Structure survives: kinds, tool names, counts, whitespace shape of redacted text.
  assert.equal(output.messages.length, 2)
  assert.equal(output.messages[1].toolName, 'Bash')
  assert.equal(output.messages[1].interactionResponseStatus, 'selected')
  assert.deepEqual(
    Object.keys(output.messages[1].interactionClosure).sort(),
    ['captureOrdinal', 'observedAt', 'outcome', 'reason'])
  assert.equal(output.messages[1].interactionClosure.outcome, 'cancelled')
  assert.notEqual(output.messages[1].interactionClosure.reason, 'turn_interrupted')
  assert.notEqual(output.messages[1].questionFreeTextResponse, 'SECRET free form answer')
  assert.equal(
    output.messages[0].text.split(' ').length, SECRET_TEXT.split(' ').length,
    'redaction preserves word structure for size-faithful fixtures')
})

test('C1.4 order and local-link fields retain structure without retaining source ids', () => {
  const source = sample()
  const { output } = run(source, 'seed-one')

  assert.equal(output.captureOrdinalHighWatermark, 12)
  assert.equal(output.messages[0].captureOrdinal, 1)
  assert.equal(output.messages[1].toolResultCaptureOrdinal, 3)
  assert.equal(output.messages[1].toolTerminalCaptureOrdinal, 4)
  assert.equal(output.messages[1].supersessionCaptureOrdinal, 5)
  assert.equal(output.messages[1].interactionResponseCaptureOrdinal, 6)
  assert.equal(output.messages[1].interactionAcknowledgedCaptureOrdinal, 7)
  assert.equal(output.messages[1].interactionClosure.captureOrdinal, 8)
  const sanitizedSubagent = output.subagents[Object.keys(output.subagents)[0]]
  assert.equal(sanitizedSubagent.startedCaptureOrdinal, 9)
  assert.equal(sanitizedSubagent.endedCaptureOrdinal, 10)
  assert.equal(output.agentActivity[0].captureOrdinal, 11)
  assert.notEqual(
    output.messages[1].supersessionEventID,
    source.messages[1].supersessionEventID,
    'record-local ids are still pseudonymized in a shareable derivative')
  assert.notEqual(output.messages[1].providerFrameUUID, source.messages[1].providerFrameUUID)
  assert.notEqual(
    output.messages[1].supersededByFrameUUID,
    source.messages[1].supersededByFrameUUID)
  assert.equal(
    output.messages[1].supersededByEntryID,
    output.messages[0].id,
    'the supersession replacement edge must survive through the shared id map')
})

test('unknown keys fail closed and are reported, never copied', () => {
  const { output, provenance } = runWithProvenance(sample(), 'seed-one')
  assert.equal(output.messages[1].aBrandNewFieldFromAFutureBuild, undefined)
  assert.equal(output.agentActivity[0].aBrandNewActivityFieldFromAFutureBuild, undefined)
  assert.ok(
    provenance.droppedUnknownKeys.some((k) => k.includes('aBrandNewFieldFromAFutureBuild')),
    'the report must name every unknown key so the policy can be extended deliberately')
  assert.ok(
    provenance.droppedUnknownKeys.some((k) =>
      k.includes('aBrandNewActivityFieldFromAFutureBuild')),
    'activity keys remain exact-allowlisted rather than inheriting captureOrdinal treatment')
  assert.ok(provenance.sourceDigest.startsWith('sha256:'))
  assert.ok(provenance.outputDigest.startsWith('sha256:'))
})

test('same seed is byte-deterministic; different seeds share nothing textual', () => {
  const a = run(sample(), 'seed-one')
  const b = run(sample(), 'seed-one')
  assert.equal(a.raw, b.raw, 'one seed, one byte-exact derivative — hashes are pinnable')
  const c = run(sample(), 'seed-two')
  assert.notEqual(a.output.title, c.output.title)
  assert.notEqual(a.output.id, c.output.id)
})

test('pseudonyms are consistent across references and UUID-shaped; time deltas survive', () => {
  const { output } = run(sample(), 'seed-one')
  const toolUseID = output.messages[1].toolUseId
  const subagentKeys = Object.keys(output.subagents)
  assert.equal(subagentKeys.length, 1)
  assert.equal(
    subagentKeys[0], toolUseID,
    'the tool row and its subagent record must still correlate after pseudonymization')
  assert.match(
    output.id,
    /^[0-9A-F]{8}-[0-9A-F]{4}-4[0-9A-F]{3}-A[0-9A-F]{3}-[0-9A-F]{12}$/,
    'pseudonyms must decode as UUIDs on the Swift side')
  const delta = Date.parse(output.messages[1].observedAt) - Date.parse(output.messages[0].observedAt)
  assert.equal(delta, 60000, 'the one shared shift preserves every inter-event delta exactly')
})
