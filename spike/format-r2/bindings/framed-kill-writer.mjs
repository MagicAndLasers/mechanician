// Child-process crash injector for the framed format-review evidence. This is not a writer candidate.
// The parent kills this process only after the requested bytes have reached fsync(2), making the
// committed-versus-torn recovery boundary deterministic instead of racing a timer.
import fs from 'node:fs'
import { crc32 } from './binding-framed.mjs'

const [mode, filePath] = process.argv.slice(2)
if (!['committed', 'torn'].includes(mode) || !filePath) {
  process.stderr.write('usage: framed-kill-writer.mjs <committed|torn> <existing-file>\n')
  process.exit(64)
}

const event = {
  kind: 'tool_result',
  agentId: 'root',
  toolUseId: mode === 'committed' ? 'killed-after-fsync' : 'killed-mid-frame',
  result: mode === 'committed' ? 'durable' : 'this payload is intentionally incomplete',
}
const payload = Buffer.from(JSON.stringify(event))
const header = Buffer.alloc(8)
header.writeUInt32LE(payload.length, 0)
header.writeUInt32LE(crc32(payload), 4)
const completeFrame = Buffer.concat([header, payload])
const bytes = mode === 'committed'
  ? completeFrame
  : completeFrame.subarray(0, 8 + Math.floor(payload.length / 2))

const descriptor = fs.openSync(filePath, 'a')
try {
  fs.writeSync(descriptor, bytes)
  fs.fsyncSync(descriptor)
} finally {
  fs.closeSync(descriptor)
}

process.stdout.write(`READY ${mode} ${bytes.length}\n`, () => {
  // The parent sends SIGKILL after observing READY. Keep an event-loop handle alive so this is a
  // real process-death boundary, not a successful child exit mislabeled as a crash.
  setInterval(() => {}, 60_000)
})
