import test from 'node:test'
import assert from 'node:assert/strict'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { createMonolith } from '../bindings/binding-monolith.mjs'
import { createFramed } from '../bindings/binding-framed.mjs'
import { createChunked } from '../bindings/binding-chunked.mjs'

const scratch = () => fs.mkdtempSync(path.join(os.tmpdir(), 'r2-bind-test-'))
const events = (n) => Array.from({ length: n }, (_, i) => ({
  kind: 'tool_result', agentId: 'root', toolUseId: `e-${i}`, result: `result ${i}`,
}))

test('all three bindings round-trip build + commits + tail + full decode', () => {
  const dir = scratch()
  for (const binding of [
    createMonolith(path.join(dir, 'm.json')),
    createFramed(path.join(dir, 'f.bin')),
    createChunked(path.join(dir, 'c.pkg')),
  ]) {
    binding.build(events(1200))
    binding.commitBoundary({ kind: 'tool_result', agentId: 'root', toolUseId: 'new', result: 'fresh' })
    const tail = binding.openTail(5)
    assert.equal(tail.at(-1).toolUseId, 'new', `${binding.name}: tail sees the newest commit`)
    assert.equal(binding.fullDecode().length, 1201, `${binding.name}: full decode is complete`)
    binding.compact()
    assert.equal(binding.fullDecode().length, 1201, `${binding.name}: compaction loses nothing`)
  }
  fs.rmSync(dir, { recursive: true, force: true })
})

test('framed: a torn tail frame is truncated by recovery; loss is bounded to that one frame', () => {
  const dir = scratch()
  const file = path.join(dir, 'f.bin')
  const binding = createFramed(file)
  binding.build(events(100))
  binding.commitBoundary({ kind: 'tool_result', agentId: 'root', toolUseId: 'committed', result: 'ok' })
  const intact = fs.statSync(file).size
  // Crash mid-append: header written, payload half-written.
  const torn = Buffer.alloc(8 + 40)
  torn.writeUInt32LE(300, 0) // claims 300 payload bytes; only 40 follow
  fs.appendFileSync(file, torn)
  assert.equal(binding.recover(), 101, 'every completed frame survives')
  assert.equal(fs.statSync(file).size, intact, 'recovery truncates exactly the torn frame')
  // Corrupt crc inside a "complete" tail frame: recovery must refuse it too.
  binding.commitBoundary({ kind: 'tool_result', agentId: 'root', toolUseId: 'later', result: 'ok' })
  const buffer = fs.readFileSync(file)
  buffer[buffer.length - 3] ^= 0xff
  fs.writeFileSync(file, buffer)
  assert.equal(binding.recover(), 101, 'a checksum-invalid tail frame is dropped, not trusted')
  fs.rmSync(dir, { recursive: true, force: true })
})

test('chunked: the head is the commit point — orphan chunks collect, torn head tmp is inert', () => {
  const dir = scratch()
  const pkg = path.join(dir, 'c.pkg')
  const binding = createChunked(pkg)
  binding.build(events(750))
  // Crash AFTER a chunk publish, BEFORE its head replace: hand-plant an orphan chunk.
  fs.writeFileSync(path.join(pkg, 'chunks', 'deadbeefdeadbeef.json'),
    JSON.stringify([{ kind: 'tool_result', toolUseId: 'orphan' }]))
  // Crash mid-head-replace: a torn tmp beside an intact head.
  fs.writeFileSync(path.join(pkg, 'head.json.tmp'), '{"chunks": [{"na')
  assert.equal(binding.recover(), 750, 'the intact head defines the record')
  assert.ok(!fs.existsSync(path.join(pkg, 'chunks', 'deadbeefdeadbeef.json')), 'orphan collected')
  assert.ok(!fs.existsSync(path.join(pkg, 'head.json.tmp')), 'torn tmp removed')
  assert.equal(binding.fullDecode().length, 750)
  fs.rmSync(dir, { recursive: true, force: true })
})

test('monolith: a torn tmp never touches the last renamed version', () => {
  const dir = scratch()
  const file = path.join(dir, 'm.json')
  const binding = createMonolith(file)
  binding.build(events(50))
  fs.writeFileSync(`${file}.tmp`, '{"events": [{"tor')
  assert.equal(binding.recover(), 50)
  fs.rmSync(dir, { recursive: true, force: true })
})
