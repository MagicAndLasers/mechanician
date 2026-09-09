// The format-review physical-binding bench: every candidate over the approved corpus, measured against
// the thresholds sheet (format-review-thresholds.md). This file measures; the thresholds judge.
//
// fsync note for the artifact: Node's fsyncSync is fsync(2); macOS fsync does not guarantee
// platter-durable F_FULLFSYNC. All candidates use the same call, so the COMPARISON is fair; the
// production sync-tier policy (grouped barriers, FULLFSYNC at checkpoints) is a P2 decision.
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { performance } from 'node:perf_hooks'
import { canonicalFromSidecar } from '../canonical-from-sidecar.mjs'
import { createMonolith } from './binding-monolith.mjs'
import { createFramed } from './binding-framed.mjs'
import { createChunked } from './binding-chunked.mjs'

// The measurement corpus is real Conversation data and is deliberately not in this repository.
// Point MECHANICIAN_FORMAT_CORPUS at a directory of Conversation JSON to reproduce these numbers.
const CORPUS = process.env.MECHANICIAN_FORMAT_CORPUS
if (!CORPUS) {
  console.error('set MECHANICIAN_FORMAT_CORPUS to a directory of Conversation JSON files')
  process.exit(2)
}
const BOUNDARY_COMMITS = 20

const boundaryEvent = (i) => ({
  kind: 'tool_result', agentId: 'root', toolUseId: `bench-${i}`,
  result: 'x'.repeat(2048), isError: false,
  observedAt: new Date(0).toISOString(), timeProvenance: 'bench',
})

const quantiles = (samples) => {
  const sorted = [...samples].sort((a, b) => a - b)
  const at = (q) => sorted[Math.min(sorted.length - 1, Math.floor(q * sorted.length))]
  return { p50: Math.round(at(0.5) * 100) / 100, p95: Math.round(at(0.95) * 100) / 100 }
}

export function benchOne(filePath) {
  const sidecar = JSON.parse(fs.readFileSync(filePath))
  const events = canonicalFromSidecar(sidecar).events
  const results = { file: path.basename(filePath), sourceBytes: fs.statSync(filePath).size, events: events.length, bindings: {} }

  const scratch = fs.mkdtempSync(path.join(os.tmpdir(), 'r2-bindings-'))
  const candidates = [
    createMonolith(path.join(scratch, 'record.json')),
    createFramed(path.join(scratch, 'record.mechframes')),
    createChunked(path.join(scratch, 'record.package')),
  ]

  for (const binding of candidates) {
    const t0 = performance.now()
    binding.build(events)
    const buildMs = performance.now() - t0

    const latencies = []
    let bytesPerCommit = 0
    for (let i = 0; i < BOUNDARY_COMMITS; i += 1) {
      const c0 = performance.now()
      bytesPerCommit = binding.commitBoundary(boundaryEvent(i))
      latencies.push(performance.now() - c0)
    }

    const tailStart = performance.now()
    const tail = binding.openTail(50)
    const openTailMs = performance.now() - tailStart

    const fullStart = performance.now()
    const decoded = binding.fullDecode()
    const fullDecodeMs = performance.now() - fullStart

    const compactStart = performance.now()
    binding.compact()
    const compactMs = performance.now() - compactStart

    results.bindings[binding.name] = {
      buildMs: Math.round(buildMs),
      commitLatencyMs: quantiles(latencies),
      bytesWrittenPerCommit: bytesPerCommit,
      openTailMs: Math.round(openTailMs * 100) / 100,
      fullDecodeMs: Math.round(fullDecodeMs),
      compactMs: Math.round(compactMs),
      integrity: {
        tailLength: tail.length,
        decodedEvents: decoded.length,
        expectedEvents: events.length + BOUNDARY_COMMITS,
      },
    }
  }
  fs.rmSync(scratch, { recursive: true, force: true })
  return results
}

if (import.meta.url.endsWith((process.argv[1] ?? '').split('/').pop() ?? '')) {
  const files = fs.readdirSync(CORPUS).filter((f) => f.endsWith('.json') && !f.includes('provenance'))
  const all = files.map((f) => benchOne(path.join(CORPUS, f)))
  console.log(JSON.stringify(all, null, 1))
}
