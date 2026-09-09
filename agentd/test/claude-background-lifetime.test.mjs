import assert from 'node:assert/strict'
import { test } from 'node:test'

import { createClaudeBackgroundLifetimeGate } from '../src/claude-background-lifetime.mjs'

const result = { type: 'result' }
const rootOutput = { type: 'stream_event' }

function tasks(...entries) {
  return { type: 'system', subtype: 'background_tasks_changed', tasks: entries }
}

test('a legacy Claude result retains the established close behavior', () => {
  const gate = createClaudeBackgroundLifetimeGate()
  assert.equal(gate.observe(result), true)
})

test('an empty or ambient-only background level does not hold a Claude turn', () => {
  for (const level of [tasks(), tasks({ task_id: 'watcher', ambient: true })]) {
    const gate = createClaudeBackgroundLifetimeGate()
    assert.equal(gate.observe(level), false)
    assert.equal(gate.observe(result), true)
  }
})

test('a Claude result stays open through live work and a synthetic completion cycle', () => {
  const gate = createClaudeBackgroundLifetimeGate()

  assert.equal(gate.observe(tasks({ task_id: 'workflow-1' })), false)
  assert.equal(gate.observe(rootOutput, { rootResponseActivity: true }), false)
  assert.equal(gate.observe(result), false, 'the root result must not strand live children')

  assert.equal(gate.observe(tasks()), false)
  assert.equal(gate.observe(result), false,
    'a zero-output task-notification result must not close before the root responds')

  assert.equal(gate.observe(rootOutput, { rootResponseActivity: true }), false)
  assert.equal(gate.observe(result), true,
    'the result after the post-workflow root response closes the input')
})

test('new live work supersedes root activity observed after a deferred result', () => {
  const gate = createClaudeBackgroundLifetimeGate()

  gate.observe(tasks({ task_id: 'workflow-1' }))
  assert.equal(gate.observe(result), false)
  gate.observe(rootOutput, { rootResponseActivity: true })
  gate.observe(tasks({ task_id: 'workflow-2' }))
  assert.equal(gate.observe(result), false)
  gate.observe(tasks())
  assert.equal(gate.observe(rootOutput, { rootResponseActivity: true }), false)
  assert.equal(gate.observe(result), true)
})
