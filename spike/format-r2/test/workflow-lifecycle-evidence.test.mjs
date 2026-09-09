import test from 'node:test'
import assert from 'node:assert/strict'
import crypto from 'node:crypto'
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

import {
  C15_EVIDENCE_VERSION,
  C15_FIXTURE_SHA256,
  C15_PREDECESSOR_SHA256,
  buildWorkflowLifecycleEvidence,
  collectWorkflowLifecycleProof,
  currentWorkflowOracleSnapshot,
} from '../workflow-lifecycle-evidence.mjs'

const here = path.dirname(fileURLToPath(import.meta.url))
const repo = path.resolve(here, '..', '..', '..')
const fixturePath = path.join(
  repo, 'agentd', 'test', 'fixtures', 'format-review-workflow-lifecycle-fixture.mjs')
const cases = [4, 5, 6, 7].map((id) => ({
  id, status: 'partial-seed-available', fixtureRefs: ['agentd-format-review-workflow-lifecycle'],
}))
const predecessor = {
  evidenceVersion: 6,
  reviewedSidecarInventory: {
    observedCorpus: {
      dispositions: {
        canonical: 26, 'intentionally-omitted': 3,
        'not-yet-captured': 82, 'private-local': 3,
      },
    },
    reviewedProductionSchemaOnly: { paths: 35 },
  },
  reviewedCaptureSurface: {
    totalDispositions: {
      canonical: 138, 'derived-projection': 2, 'intentionally-omitted': 60,
      'not-yet-captured': 30, 'private-local': 6,
    },
  },
}

async function runtime() {
  return {
    source: { commit: 'a'.repeat(40), cleanTree: true },
    predecessor: {
      relativePath:
        'docs/mechanician/agent-document-format/r2-chronology-supersession-coverage-2026-08-03.json',
      sha256: C15_PREDECESSOR_SHA256,
      document: predecessor,
    },
    fixture: {
      path: path.relative(repo, fixturePath),
      sha256: C15_FIXTURE_SHA256,
    },
    fixtures: [{
      path: path.relative(repo, fixturePath),
      sha256: C15_FIXTURE_SHA256,
    }],
    corpusManifest: {
      relativePath: 'docs/mechanician/agent-document-format/corpus-manifest.json',
      sha256: 'b'.repeat(64),
      document: { cases },
    },
    oracle: currentWorkflowOracleSnapshot(),
    proof: await collectWorkflowLifecycleProof(fixturePath),
  }
}

test('v7 proof closes workflow gaps without inventing retry or cancellation', async () => {
  const input = await runtime()
  const first = buildWorkflowLifecycleEvidence(input)
  const second = buildWorkflowLifecycleEvidence(structuredClone(input))
  assert.deepEqual(first, second)
  assert.equal(first.evidenceVersion, C15_EVIDENCE_VERSION)
  assert.equal(first.workflowLifecycle.graph.workflows, 1)
  assert.equal(first.workflowLifecycle.graph.phases, 1)
  assert.equal(first.workflowLifecycle.graph.workflowAgents, 1)
  assert.equal(first.workflowLifecycle.postRootTerminalCaptured, true)
  assert.equal(first.workflowLifecycle.terminalMonotonicity.terminalState, 'failed')
  assert.equal(first.workflowLifecycle.terminalMonotonicity.staleReportedState, 'progress')
  assert.equal(first.workflowLifecycle.repeatedIdenticalToolObservations, 2)
  assert.equal(first.workflowLifecycle.terminalRefinement.workflowAgentCount, 1)
  assert.equal(first.workflowLifecycle.legacySidecar.degradedLifecycleEvents, 1)
  assert.ok(Object.values(first.workflowLifecycle.roots).every(
    (root) => root.structuralMisses === 0 && root.unclassifiedDifferences === 0))
  assert.ok(first.stopGaps.some((gap) => gap.includes('retryOf')))
  assert.ok(first.stopGaps.some((gap) => gap.includes('cancellation')))
  assert.equal(first.reviewedCaptureSurface.totalDispositions['not-yet-captured'], undefined)
  assert.equal(
    first.deltaFromPredecessor.captureDispositions['not-yet-captured'],
    -30)
})

test('v7 builder refuses dirty source, predecessor drift, and incomplete proof', async () => {
  const clean = await runtime()
  for (const mutate of [
    (value) => { value.source.cleanTree = false },
    (value) => { value.predecessor.sha256 = '0'.repeat(64) },
    (value) => { value.fixture.sha256 = '0'.repeat(64) },
    (value) => {
      value.proof.roots['A:vcon+agent_session'].unclassifiedDifferences = 1
    },
    (value) => { value.proof.postRootTerminalCaptured = false },
  ]) {
    const changed = structuredClone(clean)
    mutate(changed)
    assert.throws(() => buildWorkflowLifecycleEvidence(changed),
      /C1\.5 evidence invariant failed/)
  }
})

test('pinned workflow fixture digest matches the reviewed source contract', () => {
  const digest = crypto.createHash('sha256').update(fs.readFileSync(fixturePath)).digest('hex')
  assert.equal(digest, C15_FIXTURE_SHA256)
})
