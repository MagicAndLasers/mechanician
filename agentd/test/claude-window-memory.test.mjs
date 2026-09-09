/**
 * The measured-window cache. Its whole job is to replace a guess with what the provider actually
 * served, so the two things that matter are that a measurement survives a restart and that nothing
 * about this cache can ever fail a turn.
 */
import { test } from 'node:test'
import assert from 'node:assert/strict'

import {
  CLAUDE_WINDOW_MEASUREMENT_MAX_AGE_MS,
  createClaudeWindowMemory,
} from '../src/claude-window-memory.mjs'

/// A backing file that lives in memory, so a test can restart the memory against the same bytes.
function fakeFile(initial = null) {
  const file = { text: initial, writes: 0 }
  return {
    file,
    readText: () => file.text,
    writeText: (text) => { file.text = text; file.writes += 1 },
  }
}

test('a measurement is remembered and survives a restart', () => {
  const { file, readText, writeText } = fakeFile()
  let clock = 1_000
  const memory = createClaudeWindowMemory({ readText, writeText, now: () => clock })

  assert.equal(memory.get('claude-opus-4-8[1m]'), null, 'nothing measured yet')
  assert.equal(memory.record('claude-opus-4-8[1m]', 1_000_000), true, 'first record is a change')
  assert.equal(memory.get('claude-opus-4-8[1m]'), 1_000_000)

  // The point of persisting: a relaunch must not go back to guessing. This is the Vertex case,
  // where the preflight is bypassed and the terminal result is the only measurement we ever get.
  clock += 5_000
  const restarted = createClaudeWindowMemory({ readText, writeText, now: () => clock })
  assert.equal(restarted.get('claude-opus-4-8[1m]'), 1_000_000)
  assert.ok(file.text.includes('claude-opus-4-8[1m]'))
})

test('recording the same window again is not reported as a change', () => {
  const { readText, writeText } = fakeFile()
  const memory = createClaudeWindowMemory({ readText, writeText })
  assert.equal(memory.record('claude-sonnet-5', 1_000_000), true)
  assert.equal(memory.record('claude-sonnet-5', 1_000_000), false, 'steady state is quiet')
  // A route whose served window really did change must report it, so the app can stop showing the
  // old number in the picker and the downshift warning.
  assert.equal(memory.record('claude-sonnet-5', 200_000), true)
  assert.equal(memory.get('claude-sonnet-5'), 200_000)
})

test('model ids are compared case-insensitively and trimmed', () => {
  const { readText, writeText } = fakeFile()
  const memory = createClaudeWindowMemory({ readText, writeText })
  memory.record('  Claude-Opus-4-8[1M]  ', 1_000_000)
  assert.equal(memory.get('claude-opus-4-8[1m]'), 1_000_000)
  assert.equal(memory.get('CLAUDE-OPUS-4-8[1M]'), 1_000_000)
})

test('only a positive integer window is accepted', () => {
  const { readText, writeText } = fakeFile()
  const memory = createClaudeWindowMemory({ readText, writeText })
  for (const bad of [0, -1, 1.5, NaN, Infinity, '1000000', null, undefined, {}]) {
    assert.equal(memory.record('claude-opus-5', bad), false, String(bad))
  }
  assert.equal(memory.get('claude-opus-5'), null)
  // An empty or non-string id is refused too, so a missing model never becomes a shared entry.
  assert.equal(memory.record('', 1_000_000), false)
  assert.equal(memory.record(null, 1_000_000), false)
})

test('an unreadable or malformed file behaves exactly like no file', () => {
  // Every one of these means "fall back to the assumption for one turn and re-measure". None of
  // them may throw, because this runs on the path that decides whether a turn can start.
  const cases = [
    () => { throw new Error('permission denied') },
    () => null,
    () => '',
    () => '   ',
    () => 'not json at all',
    () => '{"version":999,"models":{"claude-opus-5":{"window":1000000}}}',
    () => '{"version":1}',
    () => '{"version":1,"models":null}',
    () => '{"version":1,"models":{"claude-opus-5":{"window":-5,"observedAt":1}}}',
    () => '{"version":1,"models":{"":{"window":1000000,"observedAt":1}}}',
    () => '[]',
  ]
  for (const readText of cases) {
    const memory = createClaudeWindowMemory({ readText, writeText: () => {} })
    assert.equal(memory.get('claude-opus-5'), null)
    assert.deepEqual(memory.snapshot(), {})
    // Still usable afterwards: a bad file must not poison the session.
    assert.equal(memory.record('claude-opus-5', 1_000_000), true)
    assert.equal(memory.get('claude-opus-5'), 1_000_000)
  }
})

test('a failing write costs a re-measurement, never a turn', () => {
  const memory = createClaudeWindowMemory({
    readText: () => null,
    writeText: () => { throw new Error('read-only volume') },
  })
  assert.equal(memory.record('claude-opus-5', 1_000_000), true)
  // The in-memory answer is still correct for the rest of this process.
  assert.equal(memory.get('claude-opus-5'), 1_000_000)
})

test('a measurement older than the maximum age is discarded, not trusted', () => {
  // A served window can change under us when an entitlement is granted or withdrawn. An actively
  // used model re-records every completed turn, so only a long-unused one can reach this.
  const { readText, writeText } = fakeFile()
  let clock = 1_000_000
  const memory = createClaudeWindowMemory({ readText, writeText, now: () => clock })
  memory.record('claude-opus-4-8[1m]', 1_000_000)
  clock += CLAUDE_WINDOW_MEASUREMENT_MAX_AGE_MS - 1
  assert.equal(memory.get('claude-opus-4-8[1m]'), 1_000_000, 'still inside the window')
  clock += 2
  assert.equal(memory.get('claude-opus-4-8[1m]'), null, 'expired back to the assumption')
  assert.deepEqual(memory.snapshot(), {})
})

test('the file is bounded, evicting the oldest observation first', () => {
  const { readText, writeText } = fakeFile()
  let clock = 1_000
  const memory = createClaudeWindowMemory({
    readText, writeText, now: () => clock, maximumEntries: 3,
  })
  for (const id of ['a', 'b', 'c', 'd']) {
    memory.record(id, 200_000)
    clock += 1_000
  }
  const snapshot = memory.snapshot()
  assert.deepEqual(Object.keys(snapshot).sort(), ['b', 'c', 'd'])
  assert.equal(memory.get('a'), null, 'oldest evicted')
  // Re-recording the survivor keeps it, so the models actually in use are the ones retained.
  memory.record('b', 200_000)
  assert.equal(memory.get('b'), 200_000)
})

test('a snapshot reports every live measurement for the app', () => {
  const { readText, writeText } = fakeFile()
  const memory = createClaudeWindowMemory({ readText, writeText })
  memory.record('claude-opus-4-8[1m]', 1_000_000)
  memory.record('claude-opus-4-8', 200_000)
  // The picker needs exactly this: the same family at two windows, so the two adjacent rows can
  // stop looking interchangeable.
  assert.deepEqual(memory.snapshot(), {
    'claude-opus-4-8[1m]': 1_000_000,
    'claude-opus-4-8': 200_000,
  })
})
