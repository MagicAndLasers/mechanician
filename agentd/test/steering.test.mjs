import assert from 'node:assert/strict'
import { test } from 'node:test'

import { SteeringInput, claudeUserMessage } from '../src/steering.mjs'

test('steering input delivers queued and awaited values in order, then closes', async () => {
  const input = new SteeringInput()
  input.push('first')
  assert.deepEqual(await input.next(), { value: 'first', done: false })

  const waiting = input.next()
  input.push('second')
  assert.deepEqual(await waiting, { value: 'second', done: false })

  input.close()
  assert.deepEqual(await input.next(), { value: undefined, done: true })
  assert.equal(input.push('late'), false)
})

test('Claude guidance uses the provider SDK next-message priority', () => {
  assert.deepEqual(claudeUserMessage('Please keep the current layout.', 'next'), {
    type: 'user',
    message: {
      role: 'user',
      content: [{ type: 'text', text: 'Please keep the current layout.' }],
    },
    parent_tool_use_id: null,
    priority: 'next',
    shouldQuery: true,
  })
})
