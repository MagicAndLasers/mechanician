import assert from 'node:assert/strict'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import test from 'node:test'
import { claudeCompactionSummaryEvent } from '../src/claude-compaction-summary.mjs'

test('PostCompact exposes the exact root continuity summary with correlation', () => {
  assert.deepEqual(claudeCompactionSummaryEvent('turn-1', {
    hook_event_name: 'PostCompact',
    trigger: 'manual',
    compact_summary: 'Keep the storage invariant.\nContinue with the failing test.',
    session_id: 'session-private',
    prompt_id: 'prompt-1',
  }, { compactionSequence: 1 }), {
    type: 'compaction_summary',
    id: 'turn-1',
    trigger: 'manual',
    compactionSequence: 1,
    summary: 'Keep the storage invariant.\nContinue with the failing test.',
    summarySource: 'claude_post_compact',
    summaryTruncated: false,
    summaryBytes: 59,
    sessionId: 'session-private',
    promptId: 'prompt-1',
  })
})

test('subagent and malformed PostCompact payloads do not become root boundaries', () => {
  assert.equal(claudeCompactionSummaryEvent('turn-1', {
    hook_event_name: 'PostCompact',
    compact_summary: 'child summary',
    agent_id: 'child-1',
  }, { compactionSequence: 1 }), null)
  assert.equal(claudeCompactionSummaryEvent('turn-1', {
    hook_event_name: 'PreCompact',
    compact_summary: 'not complete',
  }, { compactionSequence: 1 }), null)
  assert.equal(claudeCompactionSummaryEvent('turn-1', {
    hook_event_name: 'PostCompact',
    compact_summary: '   ',
  }, { compactionSequence: 1 }), null)
})

test('oversized summaries are UTF-8 bounded and explicitly marked', () => {
  const event = claudeCompactionSummaryEvent('turn-1', {
    hook_event_name: 'PostCompact',
    compact_summary: 'abc🙂def',
    session_id: 'session-1',
  }, { compactionSequence: 1, maxSummaryBytes: 6 })

  assert.equal(event.summary, 'abc')
  assert.equal(event.summaryTruncated, true)
  assert.ok(Buffer.byteLength(event.summary, 'utf8') <= 6)
})

test('a genuine trailing replacement character survives scalar-safe truncation', () => {
  const event = claudeCompactionSummaryEvent('turn-1', {
    hook_event_name: 'PostCompact',
    compact_summary: 'a\uFFFDz',
  }, { compactionSequence: 1, maxSummaryBytes: 4 })

  assert.equal(event.summary, 'a\uFFFD')
  assert.equal(event.summaryTruncated, true)
})

test('large summaries use a bounded temp-file handoff instead of the NDJSON payload', (t) => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'mechanician-summary-test-'))
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }))
  const summary = 'provider continuity\n'.repeat(500)
  const event = claudeCompactionSummaryEvent('turn-1', {
    hook_event_name: 'PostCompact',
    compact_summary: summary,
  }, {
    compactionSequence: 2,
    inlineEventBytes: 512,
    tempDirectory: directory,
  })

  assert.equal(event.summary, undefined)
  assert.equal(event.compactionSequence, 2)
  assert.match(path.basename(event.summaryPath), /^mechanician-compaction-.+\.summary$/)
  assert.equal(fs.readFileSync(event.summaryPath, 'utf8'), summary)
  assert.ok(Buffer.byteLength(JSON.stringify(event), 'utf8') + 1 <= 512)
})
