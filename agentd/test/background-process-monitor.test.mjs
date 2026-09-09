import assert from 'node:assert/strict'
import { setImmediate as delayUntilImmediate } from 'node:timers/promises'
import { test } from 'node:test'

import {
  createBackgroundProcessMonitor,
  createBackgroundProcessPublicationGate,
} from '../src/background-process-monitor.mjs'

const deferred = () => {
  let resolve
  let reject
  const promise = new Promise((res, rej) => { resolve = res; reject = rej })
  return { promise, resolve, reject }
}

function fakeScheduler() {
  const pending = []
  const cancelled = []
  return {
    pending,
    cancelled,
    schedule(callback, delay) {
      const handle = {
        callback,
        delay,
        unrefCalls: 0,
        unref() { this.unrefCalls += 1 },
      }
      pending.push(handle)
      return handle
    },
    cancel(handle) {
      cancelled.push(handle)
      const index = pending.indexOf(handle)
      if (index >= 0) pending.splice(index, 1)
    },
    fireNext() {
      const handle = pending.shift()
      assert.ok(handle, 'expected a scheduled background poll')
      handle.callback()
      return handle
    },
  }
}

test('a successful Stop forces the next process snapshot to publish', () => {
  const published = []
  const gate = createBackgroundProcessPublicationGate((processes) => published.push(processes))
  const process = { pid: 20, detached: true }

  assert.equal(gate.publish([]), false, 'the initial empty set is not useful traffic')
  assert.equal(gate.publish([process]), true)
  assert.equal(gate.publish([process]), false, 'an unchanged live set remains coalesced')

  const countBeforeInvalidation = published.length
  gate.invalidate()
  assert.equal(published.length, countBeforeInvalidation, 'invalidation itself performs no I/O')
  assert.equal(gate.publish([]), true, 'the empty snapshot removes the killed row')
  assert.deepEqual(published, [[process], []])
})

test('a process that survives Stop is republished with the same signature', () => {
  const published = []
  const gate = createBackgroundProcessPublicationGate((processes) => published.push(processes))
  const process = { pid: 20, detached: true }

  gate.publish([process])
  gate.invalidate()

  assert.equal(gate.publish([process]), true,
    'a process that ignored SIGTERM must return to the panel')
  assert.deepEqual(published, [[process], [process]])
})

test('the post-Stop publication is always the complete retained snapshot', () => {
  const published = []
  const gate = createBackgroundProcessPublicationGate((processes) => published.push(processes))
  const first = { pid: 20, detached: true }
  const retained = { pid: 21, detached: false }

  gate.publish([first, retained])
  gate.invalidate()

  assert.equal(gate.publish([retained]), true)
  assert.equal(gate.publish([retained]), false, 'the forced snapshot becomes the new baseline')
  assert.deepEqual(published, [[first, retained], [retained]])
})

test('the next background poll is armed only after the current poll settles', async () => {
  const scheduler = fakeScheduler()
  const firstPoll = deferred()
  let polls = 0
  const published = []
  const monitor = createBackgroundProcessMonitor({
    poll: async () => {
      polls += 1
      if (polls === 1) return firstPoll.promise
      return [`result-${polls}`]
    },
    publish: (processes) => published.push(processes),
    schedule: scheduler.schedule,
    cancel: scheduler.cancel,
  })

  assert.equal(scheduler.pending.length, 1)
  assert.equal(scheduler.pending[0].delay, 5_000)
  assert.equal(scheduler.pending[0].unrefCalls, 1)

  scheduler.fireNext()
  assert.equal(polls, 1)
  assert.equal(scheduler.pending.length, 0, 'no timer may exist while a poll is running')
  await Promise.resolve()
  assert.equal(scheduler.pending.length, 0)

  firstPoll.resolve(['first-result'])
  await delayUntilImmediate()
  assert.deepEqual(published, [['first-result']])
  assert.equal(scheduler.pending.length, 1)
  assert.equal(scheduler.pending[0].delay, 5_000)
  assert.equal(scheduler.pending[0].unrefCalls, 1, 'every rearmed timer must be unref\'d')
  monitor.stop()
})

test('a poll failure is contained and schedules the next pass', async () => {
  const scheduler = fakeScheduler()
  const errors = []
  let publishes = 0
  const monitor = createBackgroundProcessMonitor({
    poll: async () => { throw new Error('fixture poll failure') },
    publish: () => { publishes += 1 },
    onError: (error) => errors.push(error.message),
    schedule: scheduler.schedule,
    cancel: scheduler.cancel,
  })

  scheduler.fireNext()
  await delayUntilImmediate()
  assert.deepEqual(errors, ['fixture poll failure'])
  assert.equal(publishes, 0)
  assert.equal(scheduler.pending.length, 1)
  monitor.stop()
})

test('a disabled lane rearms without polling until real turn work enables it', async () => {
  const scheduler = fakeScheduler()
  let enabled = false
  let polls = 0
  const published = []
  const monitor = createBackgroundProcessMonitor({
    shouldPoll: () => enabled,
    poll: async () => {
      polls += 1
      return [`result-${polls}`]
    },
    publish: (processes) => published.push(processes),
    schedule: scheduler.schedule,
    cancel: scheduler.cancel,
  })

  scheduler.fireNext()
  await delayUntilImmediate()
  assert.equal(polls, 0)
  assert.deepEqual(published, [])
  assert.equal(scheduler.pending.length, 1, 'the disabled monitor still checks again later')
  assert.equal(scheduler.pending[0].unrefCalls, 1)

  enabled = true
  scheduler.fireNext()
  await delayUntilImmediate()
  assert.equal(polls, 1)
  assert.deepEqual(published, [['result-1']])
  assert.equal(scheduler.pending.length, 1)
  monitor.stop()
})

test('stop before the timer fires cancels it idempotently', () => {
  const scheduler = fakeScheduler()
  let polls = 0
  const monitor = createBackgroundProcessMonitor({
    poll: async () => { polls += 1; return [] },
    publish: () => {},
    schedule: scheduler.schedule,
    cancel: scheduler.cancel,
  })
  const handle = scheduler.pending[0]

  monitor.stop()
  monitor.stop()

  assert.deepEqual(scheduler.cancelled, [handle])
  assert.equal(scheduler.pending.length, 0)
  assert.equal(polls, 0)
})

test('stop aborts an in-flight poll and prevents publish or rearm', async () => {
  const scheduler = fakeScheduler()
  let observedSignal = null
  let publishes = 0
  const monitor = createBackgroundProcessMonitor({
    poll: ({ signal }) => new Promise((resolve, reject) => {
      observedSignal = signal
      signal.addEventListener('abort', () => reject(signal.reason), { once: true })
    }),
    publish: () => { publishes += 1 },
    schedule: scheduler.schedule,
    cancel: scheduler.cancel,
  })

  scheduler.fireNext()
  assert.equal(observedSignal?.aborted, false)
  monitor.stop()
  await delayUntilImmediate()

  assert.equal(observedSignal?.aborted, true)
  assert.equal(publishes, 0)
  assert.equal(scheduler.pending.length, 0)
})
