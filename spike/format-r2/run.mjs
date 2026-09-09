// End-to-end R2 comparison on one fixture: capture -> canonical (root C) -> encode as root A
// (vCon+agent_session) and root B (VAC) -> decode back -> loss/deviation reports.
import { fileURLToPath } from 'node:url'
import path from 'node:path'
import { captureTurn } from './capture.mjs'
import { toCanonical, skeleton } from './canonical.mjs'
import {
  canonicalDigest, classifyFieldDifferences, compareCanonicalFields,
} from './canonical-field-contract.mjs'
import { encodeVcon, decodeVcon } from './encode-vcon.mjs'
import { encodeACR, decodeACRRecord } from './encode-acr.mjs'

const here = path.dirname(fileURLToPath(import.meta.url))
const fixture = process.argv[2] ?? path.join(
  here, '..', '..', 'agentd', 'test', 'fixtures', 'nested-delegation-fixture.mjs')

export function compareSkeletons(original, decoded) {
  const misses = []
  const a = skeleton(original)
  const b = skeleton(decoded)
  const count = Math.max(a.agents.length, b.agents.length)
  for (let index = 0; index < count; index += 1) {
    if (a.agents[index] !== b.agents[index]) {
      misses.push(`agent mismatch at ${index}: ${a.agents[index] ?? '<missing>'} != ${b.agents[index] ?? '<missing>'}`)
    }
  }
  const eventCount = Math.max(a.events.length, b.events.length)
  for (let index = 0; index < eventCount; index += 1) {
    if (a.events[index] !== b.events[index]) {
      misses.push(`event mismatch at ${index}: ${a.events[index] ?? '<missing>'} != ${b.events[index] ?? '<missing>'}`)
    }
  }
  return misses
}

export function compareCanonicalFidelity(original, decoded) {
  const differences = compareCanonicalFields(original, decoded)
  const classified = classifyFieldDifferences(differences)
  return {
    digest: canonicalDigest(decoded),
    differences,
    declaredPrototypeGaps: classified.declaredLosses,
    unclassifiedDifferences: classified.unclassified,
  }
}

export async function runComparison(fixturePath, captureOptions = {}) {
  const capture = await captureTurn(fixturePath, captureOptions)
  const canonical = toCanonical(capture)

  const vconEncoded = encodeVcon(canonical)
  const acrEncoded = encodeACR(canonical)
  const vconDecoded = decodeVcon(vconEncoded)
  const acrDecoded = decodeACRRecord(acrEncoded.record)
  const vconFidelity = compareCanonicalFidelity(canonical, vconDecoded)
  const acrFidelity = compareCanonicalFidelity(canonical, acrDecoded)

  const results = {
    fixture: path.basename(fixturePath),
    canonical: {
      agents: canonical.agents.length,
      events: canonical.events.length,
      bytes: JSON.stringify(canonical).length,
    },
    roots: {
      'A:vcon+agent_session': {
        bytes: JSON.stringify(vconEncoded.vcon).length,
        structuralMisses: compareSkeletons(canonical, vconDecoded),
        ...vconFidelity,
        deviations: vconEncoded.ledger.deviations,
        extensions: [...new Set(vconEncoded.ledger.extensions)],
        losses: [...new Set(vconEncoded.ledger.losses)],
      },
      'B:acr-vac': {
        bytes: JSON.stringify(acrEncoded.record).length,
        structuralMisses: compareSkeletons(canonical, acrDecoded),
        ...acrFidelity,
        deviations: acrEncoded.ledger.deviations,
        extensions: [...new Set(acrEncoded.ledger.extensions)],
        losses: [...new Set(acrEncoded.ledger.losses)],
      },
      'C:canonical-graph': {
        bytes: JSON.stringify(canonical).length,
        structuralMisses: [],
        digest: canonicalDigest(canonical),
        differences: [],
        declaredPrototypeGaps: [],
        unclassifiedDifferences: [],
        deviations: [],
        extensions: [],
        losses: [],
        note: 'selected canonical object identity only; source-leaf coverage is tested separately and this row is not independent round-trip evidence',
      },
    },
  }
  return { capture, canonical, results }
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const { results } = await runComparison(fixture)
  console.log(JSON.stringify(results, null, 1))
}
