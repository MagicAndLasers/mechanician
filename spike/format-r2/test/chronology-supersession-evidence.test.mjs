import assert from 'node:assert/strict'
import test from 'node:test'

import {
  C14_PREDECESSOR_FILENAME,
  C14_PREDECESSOR_SHA256,
  C14_REVIEWED_SIDECAR_FIELDS,
  buildChronologySupersessionEvidence,
  chronologySupersessionProof,
  currentOracleSnapshot,
} from '../chronology-supersession-evidence.mjs'

const dispositions = Object.fromEntries(C14_REVIEWED_SIDECAR_FIELDS.map((path) => {
  if (path === 'messages[].providerFrameUUID' || path === 'messages[].supersededByFrameUUID') {
    return [path, 'intentionally-omitted']
  }
  if (path === 'captureOrdinalHighWatermark'
      || path === 'subagents.*.startedCaptureOrdinal'
      || path === 'subagents.*.endedCaptureOrdinal') {
    return [path, 'derived-projection']
  }
  if (path === 'agentActivity[].captureOrdinal') return [path, 'not-yet-captured']
  return [path, 'canonical']
}))

function runtime() {
  const predecessor = {
    evidenceVersion: 5,
    reviewedSidecarInventory: {
      observedCorpus: {
        dispositions: {
          canonical: 25, 'intentionally-omitted': 2,
          'not-yet-captured': 84, 'private-local': 3,
        },
      },
      reviewedProductionSchemaOnly: { paths: 21 },
    },
    reviewedCaptureSurface: {
      totalDispositions: {
        canonical: 138, 'derived-projection': 2, 'intentionally-omitted': 59,
        'not-yet-captured': 30, 'private-local': 6,
      },
    },
  }
  return {
    source: { commit: '1234567890abcdef1234567890abcdef12345678', cleanTree: true },
    predecessor: {
      relativePath: `docs/mechanician/agent-document-format/${C14_PREDECESSOR_FILENAME}`,
      sha256: C14_PREDECESSOR_SHA256,
      document: predecessor,
    },
    corpusManifest: {
      relativePath: 'docs/mechanician/agent-document-format/corpus-manifest.json',
      sha256: 'a'.repeat(64),
      document: {
        cases: [4, 5, 7, 12].map((id) => ({
          id, status: 'partial-seed-available', fixtureRefs: [`fixture-${id}`],
        })),
      },
    },
    fixtures: [{ path: 'spike/format-r2/chronology-supersession-evidence.mjs',
      sha256: 'b'.repeat(64) }],
    oracle: {
      reviewedSidecarInventory: {
        observedCorpus: {
          paths: 114,
          dispositions: {
            canonical: 30, 'intentionally-omitted': 4,
            'not-yet-captured': 77, 'private-local': 3,
          },
          unclassified: 0,
        },
        reviewedProductionSchemaOnly: {
          paths: 35,
          dispositions: {
            canonical: 29, 'derived-projection': 2, 'intentionally-omitted': 4,
          },
          unclassified: 0,
        },
      },
      reviewedCaptureSurface: {
        reviewedPaths: 237,
        fixtureEmitted: { paths: 149, dispositions: { canonical: 111 } },
        captureEnvelope: { paths: 55, dispositions: { canonical: 27 } },
        productionSourceOnly: {
          paths: 31, dispositions: { 'not-yet-captured': 30, 'private-local': 1 },
        },
        totalDispositions: {
          canonical: 138, 'derived-projection': 2, 'intentionally-omitted': 60,
          'not-yet-captured': 30, 'private-local': 6,
        },
        normalBaselineReachablePaths: 98,
        variantOrPostTerminalPaths: 138,
        unclassified: 0,
      },
      requiredC14FieldDispositions: C14_REVIEWED_SIDECAR_FIELDS.map((path) => ({
        path,
        classification: dispositions[path],
        reason: path === 'agentActivity[].captureOrdinal'
          ? 'path-only focused test disposition'
          : 'focused test disposition',
      })),
    },
  }
}

test('v6 proof covers complete/degraded chronology and local supersession without leaked content', () => {
  const proof = chronologySupersessionProof()
  assert.equal(proof.complete.chronology.status, 'complete')
  assert.equal(proof.complete.chronology.basis, 'record-local-capture-partial-order')
  assert.deepEqual(proof.complete.unorderedCaptureBatches, [{
    captureOrdinal: 3,
    eventIds: [
      'activity:00000000-0000-4000-a000-000000000005',
      'entry:00000000-0000-4000-a000-000000000002:result',
    ],
  }])
  assert.deepEqual(proof.complete.supersession, {
    eventId: 'supersession:00000000-0000-4000-a000-000000000004',
    targetEventId: 'entry:00000000-0000-4000-a000-000000000002',
    replacementEventId: 'entry:00000000-0000-4000-a000-000000000003',
    captureOrdinal: 8,
  })
  assert.equal(proof.complete.retainedToolEvidence.supersededButNotErased, true)
  assert.deepEqual(proof.complete.withdrawnAssistant, {
    presentBeforeReducer: true,
    absentFromPersistedSidecar: true,
    absentFromCanonicalRecord: true,
  })
  assert.equal(proof.complete.rawProviderHandlesExcluded, true)
  assert.equal(proof.degraded.chronology.status, 'degraded')
  assert.equal(proof.degraded.chronology.diagnostic, 'cross-source-order-unavailable')
  assert.deepEqual(proof.degraded.preservedTraversalKinds, [
    'agent_spawn', 'user_message', 'assistant_message',
  ])
})

test('v6 evidence builder is deterministic and preserves the exact C1.3 predecessor', () => {
  const first = buildChronologySupersessionEvidence(runtime())
  const second = buildChronologySupersessionEvidence(runtime())
  assert.equal(JSON.stringify(first), JSON.stringify(second))
  assert.equal(first.evidenceVersion, 6)
  assert.equal(first.predecessor.sha256, C14_PREDECESSOR_SHA256)
  assert.match(first.predecessor.path, new RegExp(`${C14_PREDECESSOR_FILENAME}$`))
  assert.deepEqual(Object.keys(first.corpusCases), ['4', '5', '7', '12'])
  assert.equal(first.chronologyAndSupersession.complete.chronology.status, 'complete')
  assert.equal(first.chronologyAndSupersession.degraded.chronology.status, 'degraded')
  assert.ok(first.stopGaps.some((gap) => gap.includes('retry relationship')))
  assert.ok(first.stopGaps.some((gap) => gap.includes('provider-observed cancellation')))
  assert.equal(first.stopGaps.some((gap) => gap === 'retraction remains unrepresented'), false)
})

test('v6 evidence accepts the complete live C1.4 field-oracle review', () => {
  const snapshot = currentOracleSnapshot()
  const byPath = new Map(snapshot.requiredC14FieldDispositions.map((item) => [item.path, item]))
  assert.equal(byPath.get('messages[].providerFrameUUID').classification,
    'intentionally-omitted')
  assert.equal(byPath.get('messages[].supersededByFrameUUID').classification,
    'intentionally-omitted')
  assert.equal(byPath.get('subagents.*.startedCaptureOrdinal').classification,
    'derived-projection')
  assert.equal(byPath.get('agentActivity[].captureOrdinal').classification,
    'not-yet-captured')
  assert.match(byPath.get('agentActivity[].captureOrdinal').reason, /path-only/)
})

test('v6 evidence refuses dirty source, predecessor drift, and incomplete field review', () => {
  const dirty = runtime()
  dirty.source.cleanTree = false
  assert.throws(() => buildChronologySupersessionEvidence(dirty), /clean Mechanician source tree/)

  const predecessorDrift = runtime()
  predecessorDrift.predecessor.sha256 = 'c'.repeat(64)
  assert.throws(() => buildChronologySupersessionEvidence(predecessorDrift),
    /predecessor digest/)

  const unreviewed = runtime()
  unreviewed.oracle.requiredC14FieldDispositions.find(
    (item) => item.path === 'messages[].supersessionEventID').classification = 'not-yet-captured'
  assert.throws(() => buildChronologySupersessionEvidence(unreviewed), /must be canonical/)
})
