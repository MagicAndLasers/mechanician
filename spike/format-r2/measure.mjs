// R2 measurement run: the approved sanitized corpus through all three roots, timed, plus the
// today's-binding baseline (encode + atomic whole-file write — the cost every incremental
// binding candidate must beat). Numbers land beside the format-review thresholds sheet; the thresholds
// judge, this file only measures.
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { performance } from 'node:perf_hooks'
import { canonicalFromSidecar } from './canonical-from-sidecar.mjs'
import { encodeVcon, decodeVcon } from './encode-vcon.mjs'
import { encodeACR, decodeACRRecord } from './encode-acr.mjs'
import { compareCanonicalFidelity, compareSkeletons } from './run.mjs'

// The measurement corpus is real Conversation data and is deliberately not in this repository.
// Point MECHANICIAN_FORMAT_CORPUS at a directory of Conversation JSON to reproduce these numbers.
const CORPUS = process.env.MECHANICIAN_FORMAT_CORPUS
if (!CORPUS) {
  console.error('set MECHANICIAN_FORMAT_CORPUS to a directory of Conversation JSON files')
  process.exit(2)
}

const ms = (fn) => {
  const t0 = performance.now()
  const value = fn()
  return { value, ms: Math.round((performance.now() - t0) * 10) / 10 }
}

export function measureOne(filePath) {
  const bytes = fs.readFileSync(filePath)
  const parse = ms(() => JSON.parse(bytes))
  const canon = ms(() => canonicalFromSidecar(parse.value))

  // Baseline: today's persistence — re-encode the whole sidecar and atomically replace a file.
  // This is the per-mutation cost the app pays now and the number the journal must beat.
  const tmp = path.join(os.tmpdir(), `r2-baseline-${path.basename(filePath)}`)
  const baselineEncode = ms(() => JSON.stringify(parse.value))
  const baselineWrite = ms(() => {
    fs.writeFileSync(`${tmp}.tmp`, baselineEncode.value)
    fs.renameSync(`${tmp}.tmp`, tmp)
  })
  fs.rmSync(tmp, { force: true })

  const roots = {}
  const vconEncoded = ms(() => encodeVcon(canon.value))
  const vconBytes = ms(() => JSON.stringify(vconEncoded.value.vcon))
  const vconDecode = ms(() => decodeVcon(vconEncoded.value))
  const vconFidelity = compareCanonicalFidelity(canon.value, vconDecode.value)
  roots['A:vcon+agent_session'] = {
    encodeMs: vconEncoded.ms + vconBytes.ms,
    decodeMs: vconDecode.ms,
    bytes: vconBytes.value.length,
    structuralMisses: compareSkeletons(canon.value, vconDecode.value).length,
    fieldDifferences: vconFidelity.differences.length,
    declaredPrototypeGaps: vconFidelity.declaredPrototypeGaps.length,
    unclassifiedFieldDifferences: vconFidelity.unclassifiedDifferences.length,
    ledger: {
      deviations: vconEncoded.value.ledger.deviations.length,
      extensions: new Set(vconEncoded.value.ledger.extensions).size,
      losses: new Set(vconEncoded.value.ledger.losses).size,
    },
  }
  const acrEncoded = ms(() => encodeACR(canon.value))
  const acrBytes = ms(() => JSON.stringify(acrEncoded.value.record))
  const acrDecode = ms(() => decodeACRRecord(acrEncoded.value.record))
  const acrFidelity = compareCanonicalFidelity(canon.value, acrDecode.value)
  roots['B:acr-vac'] = {
    encodeMs: acrEncoded.ms + acrBytes.ms,
    decodeMs: acrDecode.ms,
    bytes: acrBytes.value.length,
    structuralMisses: compareSkeletons(canon.value, acrDecode.value).length,
    fieldDifferences: acrFidelity.differences.length,
    declaredPrototypeGaps: acrFidelity.declaredPrototypeGaps.length,
    unclassifiedFieldDifferences: acrFidelity.unclassifiedDifferences.length,
    ledger: {
      deviations: acrEncoded.value.ledger.deviations.length,
      extensions: new Set(acrEncoded.value.ledger.extensions).size,
      losses: new Set(acrEncoded.value.ledger.losses).size,
    },
  }
  const canonBytes = ms(() => JSON.stringify(canon.value))
  roots['C:canonical-graph'] = {
    encodeMs: canonBytes.ms,
    decodeMs: 0,
    bytes: canonBytes.value.length,
    structuralMisses: 0,
    fieldDifferences: 0,
    declaredPrototypeGaps: 0,
    unclassifiedFieldDifferences: 0,
    ledger: { deviations: 0, extensions: 0, losses: 0 },
  }

  return {
    file: path.basename(filePath),
    sourceBytes: bytes.length,
    counts: {
      messages: parse.value.messages?.length ?? 0,
      subagents: Object.keys(parse.value.subagents ?? {}).length,
      activity: parse.value.agentActivity?.length ?? 0,
      canonicalEvents: canon.value.events.length,
      agents: canon.value.agents.length,
    },
    parseMs: parse.ms,
    canonicalizeMs: canon.ms,
    baseline: {
      note: "today's binding: full re-encode + atomic replace per durable mutation",
      encodeMs: baselineEncode.ms,
      writeMs: baselineWrite.ms,
      totalMs: baselineEncode.ms + baselineWrite.ms,
    },
    roots,
  }
}

if (import.meta.url.endsWith((process.argv[1] ?? '').split('/').pop() ?? '')) {
  const files = fs.readdirSync(CORPUS).filter((f) => f.endsWith('.json') && !f.includes('provenance'))
  const results = files.map((f) => measureOne(path.join(CORPUS, f)))
  console.log(JSON.stringify(results, null, 1))
}
