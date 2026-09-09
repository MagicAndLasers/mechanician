import assert from 'node:assert/strict'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import test from 'node:test'
import {
  NATIVE_NOTIFICATION_ARGUMENT,
  relayNativeNotification,
} from '../src/native-notification-relay.mjs'

test('native relay keeps notification content out of argv and cleans its request', (t) => {
  const support = fs.mkdtempSync(path.join(os.tmpdir(), 'mechanician-notification-relay-'))
  t.after(() => fs.rmSync(support, { recursive: true, force: true }))
  const ambient = path.join(support, 'ambient')
  const payload = {
    title: 'Confidential title',
    body: 'Confidential response text',
    openWindowID: 'ambient',
    conversationID: null,
  }
  let delivered = null

  const result = relayNativeNotification({
    executable: '/usr/bin/true',
    ambientDirectory: ambient,
    payload,
    environment: { HOME: support },
    launch(executable, argv, options, completion) {
      assert.equal(executable, '/usr/bin/true')
      assert.equal(argv[0], NATIVE_NOTIFICATION_ARGUMENT)
      assert.equal(argv.length, 2)
      assert.ok(!argv.join(' ').includes(payload.title))
      assert.ok(!argv.join(' ').includes(payload.body))
      assert.deepEqual(options.env, { HOME: support })
      assert.equal(fs.statSync(argv[1]).mode & 0o777, 0o600)
      delivered = JSON.parse(fs.readFileSync(argv[1], 'utf8'))
      completion(null)
      assert.equal(fs.existsSync(argv[1]), false)
    },
  })

  assert.equal(result, true)
  assert.deepEqual(delivered, payload)
  assert.equal(fs.statSync(path.join(ambient, 'notification-requests')).mode & 0o777, 0o700)
})

test('native relay fails closed when no executable is configured', () => {
  const messages = []
  assert.equal(relayNativeNotification({
    executable: '',
    ambientDirectory: '/unused',
    payload: { title: 'Title', body: 'Body' },
    logger: (message) => messages.push(message),
  }), false)
  assert.match(messages.join('\n'), /no Mechanician executable/)
})
