import assert from 'node:assert/strict'
import { test } from 'node:test'

import {
  closePermissionRequestsForTurn,
  closeQuestionRequestsForTurn,
} from '../src/interaction-closure.mjs'

class ObservedMap extends Map {
  constructor(entries, actions) {
    super(entries)
    this.actions = actions
  }

  delete(key) {
    this.actions.push('delete:' + key)
    return super.delete(key)
  }
}

test('permission closure deletes ownership, emits once, then settles without a user response', () => {
  const actions = []
  const events = []
  const pending = new ObservedMap([
    ['permission-a', {
      turnId: 'turn-a', codex: true,
      resolve: (reply) => actions.push({ settle: 'permission-a', reply }),
    }],
    ['permission-b', {
      turnId: 'turn-b', codex: true,
      resolve: (reply) => actions.push({ settle: 'permission-b', reply }),
    }],
  ], actions)

  const close = () => closePermissionRequestsForTurn(pending, 'turn-a', {
    outcome: 'cancelled',
    reason: 'turn_interrupted',
    providerMessage: 'Turn interrupted.',
    emit: (event) => {
      assert.equal(pending.has(event.requestId), false)
      actions.push('emit:' + event.requestId)
      events.push(event)
    },
  })

  assert.deepEqual(close(), [{
    type: 'interaction_closed', id: 'turn-a', interactionKind: 'permission',
    requestId: 'permission-a', outcome: 'cancelled', reason: 'turn_interrupted',
  }])
  assert.deepEqual(actions, [
    'delete:permission-a',
    'emit:permission-a',
    { settle: 'permission-a', reply: { decision: 'decline' } },
  ])
  assert.deepEqual(events, [{
    type: 'interaction_closed', id: 'turn-a', interactionKind: 'permission',
    requestId: 'permission-a', outcome: 'cancelled', reason: 'turn_interrupted',
  }])
  assert.equal(Object.hasOwn(events[0], 'allow'), false)
  assert.equal(Object.hasOwn(events[0], 'always'), false)
  assert.equal(Object.hasOwn(events[0], 'message'), false)
  assert.equal(pending.has('permission-b'), true)

  assert.deepEqual(close(), [])
  assert.equal(events.length, 1)
  assert.equal(actions.some((action) => action?.settle === 'permission-b'), false)
})

test('question closure deletes ownership, emits once, then rejects without fabricating an answer', () => {
  const actions = []
  const events = []
  const pending = new ObservedMap([
    ['question-a', {
      turnId: 'turn-a',
      reject: (error) => actions.push({ reject: 'question-a', message: error.message }),
    }],
    ['question-b', {
      turnId: 'turn-b',
      reject: (error) => actions.push({ reject: 'question-b', message: error.message }),
    }],
  ], actions)

  const close = () => closeQuestionRequestsForTurn(pending, 'turn-a', {
    outcome: 'unavailable',
    reason: 'runtime_failed',
    providerMessage: 'Provider stopped.',
    emit: (event) => {
      assert.equal(pending.has(event.requestId), false)
      actions.push('emit:' + event.requestId)
      events.push(event)
    },
  })

  assert.deepEqual(close(), [{
    type: 'interaction_closed', id: 'turn-a', interactionKind: 'question',
    requestId: 'question-a', outcome: 'unavailable', reason: 'runtime_failed',
  }])
  assert.deepEqual(actions, [
    'delete:question-a',
    'emit:question-a',
    { reject: 'question-a', message: 'Provider stopped.' },
  ])
  assert.equal(Object.hasOwn(events[0], 'answers'), false)
  assert.equal(Object.hasOwn(events[0], 'freeText'), false)
  assert.equal(Object.hasOwn(events[0], 'message'), false)
  assert.equal(pending.has('question-b'), true)

  assert.deepEqual(close(), [])
  assert.equal(events.length, 1)
  assert.equal(actions.some((action) => action?.reject === 'question-b'), false)
})
