/**
 * A small push-driven async iterable for provider sessions that accept additional
 * user messages while a turn is running. Keeping this independent from the SDK
 * makes close/race behavior deterministic and unit-testable.
 */
export class SteeringInput {
  constructor() {
    this.values = []
    this.waiters = []
    this.closed = false
  }

  push(value) {
    if (this.closed) return false
    const waiter = this.waiters.shift()
    if (waiter) waiter({ value, done: false })
    else this.values.push(value)
    return true
  }

  close() {
    if (this.closed) return
    this.closed = true
    for (const waiter of this.waiters.splice(0)) waiter({ value: undefined, done: true })
  }

  next() {
    if (this.values.length) return Promise.resolve({ value: this.values.shift(), done: false })
    if (this.closed) return Promise.resolve({ value: undefined, done: true })
    return new Promise((resolve) => this.waiters.push(resolve))
  }

  [Symbol.asyncIterator]() { return this }
}

export function claudeUserMessage(text, priority = 'now') {
  return {
    type: 'user',
    message: { role: 'user', content: [{ type: 'text', text }] },
    parent_tool_use_id: null,
    priority,
    shouldQuery: true,
  }
}
