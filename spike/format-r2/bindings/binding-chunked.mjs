// Option E/G: a package directory of immutable, content-addressed event chunks plus one tiny
// atomically-replaced head. The head IS the commit point: a chunk written without a head update
// is an inert, collectable orphan (never corruption). Multi-file atomicity is therefore DEFINED
// (head-last publish + orphan collection), exactly the discipline the plans demand of packages.
import fs from 'node:fs'
import path from 'node:path'
import crypto from 'node:crypto'

const CHUNK_EVENTS = 500

export function createChunked(dirPath) {
  const chunksDir = path.join(dirPath, 'chunks')
  const headPath = path.join(dirPath, 'head.json')
  const writeChunk = (events) => {
    const payload = Buffer.from(JSON.stringify(events))
    const name = `${crypto.createHash('sha256').update(payload).digest('hex').slice(0, 16)}.json`
    fs.writeFileSync(path.join(chunksDir, name), payload)
    return { name, bytes: payload.length, count: events.length }
  }
  const writeHead = (chunks) => {
    const payload = Buffer.from(JSON.stringify({ chunks }))
    fs.writeFileSync(`${headPath}.tmp`, payload)
    fs.fsyncSync(fs.openSync(`${headPath}.tmp`, 'r+'))
    fs.renameSync(`${headPath}.tmp`, headPath)
    return payload.length
  }
  const readHead = () => JSON.parse(fs.readFileSync(headPath)).chunks

  return {
    name: 'E:chunked-package',
    build(initialEvents) {
      fs.mkdirSync(chunksDir, { recursive: true })
      const chunks = []
      let bytes = 0
      for (let i = 0; i < initialEvents.length; i += CHUNK_EVENTS) {
        const chunk = writeChunk(initialEvents.slice(i, i + CHUNK_EVENTS))
        chunks.push(chunk)
        bytes += chunk.bytes
      }
      return bytes + writeHead(chunks)
    },
    commitBoundary(event) {
      // A boundary commit is one small chunk + one small head replace — O(delta).
      const chunk = writeChunk([event])
      const chunks = [...readHead(), chunk]
      return chunk.bytes + writeHead(chunks)
    },
    openTail(count) {
      const chunks = readHead()
      const events = []
      for (let i = chunks.length - 1; i >= 0 && events.length < count; i -= 1) {
        const chunk = JSON.parse(fs.readFileSync(path.join(chunksDir, chunks[i].name)))
        events.unshift(...chunk)
      }
      return events.slice(-count)
    },
    fullDecode() {
      return readHead().flatMap(
        (chunk) => JSON.parse(fs.readFileSync(path.join(chunksDir, chunk.name))))
    },
    compact() {
      // Merge every chunk back to CHUNK_EVENTS-sized immutables, publish the new head, and
      // collect the now-unreferenced chunk files.
      const events = this.fullDecode()
      const before = new Set(readHead().map((c) => c.name))
      const bytes = this.build(events)
      const after = new Set(readHead().map((c) => c.name))
      for (const name of before) {
        if (!after.has(name)) fs.rmSync(path.join(chunksDir, name), { force: true })
      }
      return bytes
    },
    /// The head is authoritative: orphan chunks (published without a head update — the crash
    /// window) are collected, torn head tmps are inert. Returns surviving event count.
    recover() {
      fs.rmSync(`${headPath}.tmp`, { force: true })
      const referenced = new Set(readHead().map((c) => c.name))
      for (const file of fs.readdirSync(chunksDir)) {
        if (!referenced.has(file)) fs.rmSync(path.join(chunksDir, file), { force: true })
      }
      return readHead().reduce((sum, c) => sum + c.count, 0)
    },
  }
}
