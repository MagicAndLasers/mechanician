// Bounded idempotency cache for user decisions sent over the NDJSON control
// channel. The app retries with the same responseId when an acknowledgement is
// lost; the provider tool must be resolved exactly once while the accepted ack
// can be replayed any number of times.
export class ResponseAckCache {
  constructor(limit = 256) {
    this.limit = Math.max(1, Number(limit) || 256)
    this.entries = new Map()
  }

  lookup(responseId, requestId) {
    const entry = this.entries.get(responseId)
    if (!entry) return { status: 'missing' }
    if (entry.requestId !== requestId) return { status: 'collision' }
    // Refresh recency so an actively retried response is not the first evicted.
    this.entries.delete(responseId)
    this.entries.set(responseId, entry)
    return { status: 'duplicate', ack: { ...entry.ack } }
  }

  remember(responseId, requestId, ack) {
    this.entries.set(responseId, { requestId, ack: { ...ack } })
    while (this.entries.size > this.limit) {
      this.entries.delete(this.entries.keys().next().value)
    }
  }
}
