import assert from 'node:assert/strict'
import { test } from 'node:test'

import { evidenceDeltaFromPredecessor } from '../evidence-delta.mjs'

test('versioned evidence computes deltas from the predecessor nested counters', () => {
  const predecessor = {
    reviewedSidecarInventory: {
      observedCorpus: {
        dispositions: {
          canonical: 25, 'intentionally-omitted': 2, 'not-yet-captured': 84,
          'private-local': 3,
        },
      },
      reviewedProductionSchemaOnly: { paths: 13 },
    },
    reviewedCaptureSurface: {
      totalDispositions: {
        canonical: 133, 'derived-projection': 2, 'intentionally-omitted': 58,
        'not-yet-captured': 30, 'private-local': 6,
      },
    },
  }

  assert.deepEqual(evidenceDeltaFromPredecessor({
    observedSidecarDispositions: {
      canonical: 25, 'intentionally-omitted': 2, 'not-yet-captured': 84,
      'private-local': 3,
    },
    captureDispositions: {
      canonical: 138, 'derived-projection': 2, 'intentionally-omitted': 59,
      'not-yet-captured': 30, 'private-local': 6,
    },
    separatelyReviewedProductionSidecarPaths: 21,
  }, predecessor), {
    observedSidecarDispositions: {
      canonical: 0, 'intentionally-omitted': 0, 'not-yet-captured': 0,
      'private-local': 0,
    },
    captureDispositions: {
      canonical: 5, 'derived-projection': 0, 'intentionally-omitted': 1,
      'not-yet-captured': 0, 'private-local': 0,
    },
    separatelyReviewedProductionSidecarPaths: 8,
  })
})

test('versioned evidence rejects a predecessor whose nested counters are absent', () => {
  assert.throws(() => evidenceDeltaFromPredecessor({
    observedSidecarDispositions: {}, captureDispositions: {},
    separatelyReviewedProductionSidecarPaths: 0,
  }, {
    reviewedSidecarInventory: { dispositions: {} },
    reviewedCaptureSurface: { dispositions: {} },
  }), /required nested inventory counters/)
})
