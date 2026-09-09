// Baseline binding (today's shape): one JSON document, every commit re-encodes EVERYTHING and
// atomically replaces the file. Crash-safe by construction (rename), catastrophically write-
// amplified by construction (the whole record per boundary). This is the control the thresholds
// judge the incremental candidates against.
import fs from 'node:fs'

export function createMonolith(filePath) {
  let events = []
  const persist = () => {
    const payload = JSON.stringify({ events })
    fs.writeFileSync(`${filePath}.tmp`, payload)
    fs.fsyncSync(fs.openSync(`${filePath}.tmp`, 'r+'))
    fs.renameSync(`${filePath}.tmp`, filePath)
    return payload.length
  }
  return {
    name: 'A:monolith-json',
    build(initialEvents) {
      events = [...initialEvents]
      return persist()
    },
    commitBoundary(event) {
      events.push(event)
      return persist()
    },
    openTail(count) {
      const all = JSON.parse(fs.readFileSync(filePath)).events
      return all.slice(-count)
    },
    fullDecode() {
      return JSON.parse(fs.readFileSync(filePath)).events
    },
    compact() {
      return persist()
    },
    recover() {
      // Atomic replace: the file is always the last fully-renamed version; a torn .tmp is inert.
      return JSON.parse(fs.readFileSync(filePath)).events.length
    },
  }
}
