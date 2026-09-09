// Option F: one framed append-only file. Frame = [u32 length][u32 crc32][payload]; a commit is
// an append + fsync; recovery scans forward and truncates at the first torn/invalid frame, so a
// crash loses at most the frame being written. One Finder item, O(delta) commits.
//
// Deliberately the NAIVE floor: no tail index, no compression, checkpoint = full rewrite. A
// production design only gets faster than these numbers.
import fs from 'node:fs'

// Small table-driven CRC32 (IEEE) to avoid Node-version differences in zlib.crc32.
const TABLE = new Uint32Array(256).map((_, n) => {
  let c = n
  for (let k = 0; k < 8; k += 1) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1
  return c >>> 0
})
export function crc32(buffer) {
  let c = 0xffffffff
  for (let i = 0; i < buffer.length; i += 1) c = TABLE[(c ^ buffer[i]) & 0xff] ^ (c >>> 8)
  return (c ^ 0xffffffff) >>> 0
}

const frame = (event) => {
  const payload = Buffer.from(JSON.stringify(event))
  const header = Buffer.alloc(8)
  header.writeUInt32LE(payload.length, 0)
  header.writeUInt32LE(crc32(payload), 4)
  return Buffer.concat([header, payload])
}

export function createFramed(filePath) {
  return {
    name: 'F:framed-append-only',
    build(initialEvents) {
      const buffers = initialEvents.map(frame)
      const all = Buffer.concat(buffers)
      fs.writeFileSync(`${filePath}.tmp`, all)
      fs.renameSync(`${filePath}.tmp`, filePath)
      return all.length
    },
    commitBoundary(event) {
      const bytes = frame(event)
      const fd = fs.openSync(filePath, 'a')
      fs.writeSync(fd, bytes)
      fs.fsyncSync(fd)
      fs.closeSync(fd)
      return bytes.length
    },
    openTail(count) {
      // Naive tail: one sequential read, header-skip scan (no JSON parse except the tail).
      const buffer = fs.readFileSync(filePath)
      const offsets = []
      let offset = 0
      while (offset + 8 <= buffer.length) {
        const length = buffer.readUInt32LE(offset)
        if (offset + 8 + length > buffer.length) break
        offsets.push([offset + 8, length])
        offset += 8 + length
      }
      return offsets.slice(-count).map(
        ([start, length]) => JSON.parse(buffer.subarray(start, start + length)))
    },
    fullDecode() {
      const buffer = fs.readFileSync(filePath)
      const events = []
      let offset = 0
      while (offset + 8 <= buffer.length) {
        const length = buffer.readUInt32LE(offset)
        if (offset + 8 + length > buffer.length) break
        events.push(JSON.parse(buffer.subarray(offset + 8, offset + 8 + length)))
        offset += 8 + length
      }
      return events
    },
    compact() {
      return this.build(this.fullDecode())
    },
    /// Forward-scan validation: truncate at the first frame whose length overruns EOF or whose
    /// crc mismatches. Returns surviving event count — the crash-loss bound is one frame.
    recover() {
      const buffer = fs.readFileSync(filePath)
      let offset = 0
      let survivors = 0
      while (offset + 8 <= buffer.length) {
        const length = buffer.readUInt32LE(offset)
        if (offset + 8 + length > buffer.length) break
        const payload = buffer.subarray(offset + 8, offset + 8 + length)
        if (crc32(payload) !== buffer.readUInt32LE(offset + 4)) break
        survivors += 1
        offset += 8 + length
      }
      if (offset < buffer.length) {
        fs.truncateSync(filePath, offset)
      }
      return survivors
    },
  }
}
