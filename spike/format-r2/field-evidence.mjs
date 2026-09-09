// Reproducible format-review field-fidelity evidence. This reports what the spike actually proves; it
// intentionally emits blockers instead of turning classified omissions into a pass.
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import crypto from 'node:crypto'
import fs from 'node:fs'
import { execFileSync } from 'node:child_process'
import {
  REVIEWED_CAPTURE_BASELINE_EXCLUSIONS,
  REVIEWED_CAPTURE_ENVELOPE_FIELDS,
  REVIEWED_CAPTURE_EVENT_FIELDS,
  REVIEWED_CAPTURE_PRODUCTION_SOURCE_FIELDS,
  REVIEWED_CAPTURE_SOURCE_PINS,
  REVIEWED_SIDECAR_OBSERVED_FIELDS,
  auditReviewedCaptureSurface,
  canonicalDigest,
  classifySidecarField,
} from './canonical-field-contract.mjs'
import { resolveFormatEvidenceRepository } from './external-evidence-repository.mjs'
import { runComparison } from './run.mjs'

const here = path.dirname(fileURLToPath(import.meta.url))
const repo = path.resolve(here, '..', '..')
const externalEvidence = resolveFormatEvidenceRepository()
const evidenceRepository = externalEvidence.repositoryRoot
const evidenceDirectory = externalEvidence.evidenceDirectory
const fixture = (name) => path.join(repo, 'agentd', 'test', 'fixtures', name)
const sha256 = (file) => crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex')
const sourceCommit = execFileSync('git', ['rev-parse', 'HEAD'], {
  cwd: repo, encoding: 'utf8', stdio: ['ignore', 'pipe', 'inherit'],
}).trim()
const sourceTreeClean = execFileSync('git', ['status', '--porcelain'], {
  cwd: repo, encoding: 'utf8', stdio: ['ignore', 'pipe', 'inherit'],
}).trim() === ''
const predecessorPath = path.join(
  evidenceDirectory,
  'r2-field-coverage-2026-08-02.json')
const corpusManifestPath = path.join(evidenceDirectory, 'corpus-manifest.json')
const evidenceFixtures = [
  'minimal-conversation-fixture.mjs',
  'nested-delegation-fixture.mjs',
  'activity-agents-compaction-fixture.mjs',
  'format-review-lifecycle-fixture.mjs',
].map((name) => {
  const absolutePath = fixture(name)
  return { path: path.relative(repo, absolutePath), sha256: sha256(absolutePath) }
})

const countBy = (items, key) => Object.fromEntries(
  [...new Set(items.map((item) => item[key]))].sort().map((value) => [
    value, items.filter((item) => item[key] === value).length,
  ]),
)

const rootEvidence = (run) => Object.fromEntries(
  Object.entries(run.results.roots).map(([root, result]) => [root, {
    structuralMisses: result.structuralMisses.length,
    fieldDifferences: result.differences.length,
    declaredPrototypeGaps: result.declaredPrototypeGaps.length,
    unclassifiedDifferences: result.unclassifiedDifferences.length,
  }]),
)

const nested = await runComparison(fixture('nested-delegation-fixture.mjs'))
const compaction = await runComparison(fixture('activity-agents-compaction-fixture.mjs'))
const deterministicLifecycleTime = (sequence) =>
  new Date(Date.UTC(2026, 7, 3, 12, 0, sequence)).toISOString()
const minimal = await runComparison(fixture('minimal-conversation-fixture.mjs'), {
  prompt: 'Minimal retained prompt.',
  observedAtForSequence: (sequence) =>
    new Date(Date.UTC(2026, 7, 2, 12, 0, sequence)).toISOString(),
})
const lifecycleSuccess = await runComparison(fixture('format-review-lifecycle-fixture.mjs'), {
  prompt: 'success',
  promptObservedAt: '2026-08-03T11:59:59.000Z',
  observedAtForSequence: deterministicLifecycleTime,
  requireQuiescence: true,
  steeringRequests: [{
    steerId: 'steer-accepted', prompt: 'Please include the accepted steering fact.',
  }, {
    steerId: 'steer-rejected', prompt: 'This request is rejected by the fixture.',
  }],
})
const lifecycleError = await runComparison(fixture('format-review-lifecycle-fixture.mjs'), {
  prompt: 'error', observedAtForSequence: deterministicLifecycleTime, requireQuiescence: true,
})
const lifecycleInterrupted = await runComparison(fixture('format-review-lifecycle-fixture.mjs'), {
  prompt: 'interrupted', observedAtForSequence: deterministicLifecycleTime,
  requireQuiescence: true,
})
const sidecarDispositions = REVIEWED_SIDECAR_OBSERVED_FIELDS.map((path) =>
  classifySidecarField(path))
const captureAudit = auditReviewedCaptureSurface()

const evidence = {
  evidenceVersion: 3,
  asOf: '2026-08-03',
  verdict: 'synthetic-lifecycle-checkpoint-proven-format-review-blocked',
  predecessor: {
    path: path.relative(evidenceRepository, predecessorPath),
    sha256: sha256(predecessorPath),
  },
  source: {
    repository: 'mechanician',
    commit: sourceCommit,
    cleanTree: sourceTreeClean,
    generationCommand: 'node spike/format-r2/field-evidence.mjs',
    verificationCommands: [
      'node --test spike/format-r2/test/*.test.mjs',
      './scripts/check.sh',
    ],
  },
  inputs: {
    fixtures: evidenceFixtures,
    reviewedCaptureSourcePins: REVIEWED_CAPTURE_SOURCE_PINS,
    sanitizedCorpusManifest: {
      path: path.relative(evidenceRepository, corpusManifestPath),
      sha256: sha256(corpusManifestPath),
    },
  },
  reviewedSidecarInventory: {
    observedPaths: sidecarDispositions.length,
    dispositions: countBy(sidecarDispositions, 'classification'),
    unclassified: sidecarDispositions.filter((item) => !item).length,
  },
  reviewedCaptureSurface: {
    reviewedPaths: captureAudit.classified.length,
    fixtureEmittedFieldPaths: Object.values(REVIEWED_CAPTURE_EVENT_FIELDS)
      .reduce((total, fields) => total + fields.length, 0)
      - REVIEWED_CAPTURE_PRODUCTION_SOURCE_FIELDS.length,
    productionSourceOnlyFieldPaths: REVIEWED_CAPTURE_PRODUCTION_SOURCE_FIELDS.length,
    captureEnvelopePaths: REVIEWED_CAPTURE_ENVELOPE_FIELDS.length,
    normalCaptureReachablePaths:
      captureAudit.classified.length - REVIEWED_CAPTURE_BASELINE_EXCLUSIONS.size,
    variantOrPostTerminalPaths: REVIEWED_CAPTURE_BASELINE_EXCLUSIONS.size,
    dispositions: countBy(captureAudit.classified, 'classification'),
    unclassified: captureAudit.unclassified.length,
  },
  minimalCase: {
    status: 'fixture-ready',
    producerProfileCaptured: true,
    canonicalDigest: canonicalDigest(minimal.canonical),
    roots: Object.fromEntries(Object.entries(minimal.results.roots).map(([root, result]) => [
      root, {
        digest: result.digest,
        fieldDifferences: result.differences.length,
        declaredPrototypeGaps: result.declaredPrototypeGaps.length,
        unclassifiedDifferences: result.unclassifiedDifferences.length,
      },
    ])),
  },
  lifecycleCapture: {
    fixture: 'agentd/test/fixtures/format-review-lifecycle-fixture.mjs',
    provenance: 'synthetic fixture and capture-envelope evidence; not production-provider proof',
    producer: lifecycleSuccess.canonical.producer,
    profile: lifecycleSuccess.canonical.profile,
    privateResumeHandlesExcluded: [lifecycleSuccess, lifecycleError].every((run) =>
      !/PRIVATE-GATE-C-(?:RESUME|ERROR)-HANDLE/.test(JSON.stringify(run.canonical))),
    success: {
      capturedWireEvents: lifecycleSuccess.capture.events.length,
      canonicalAgents: lifecycleSuccess.canonical.agents.length,
      canonicalEvents: lifecycleSuccess.canonical.events.length,
      canonicalDigest: canonicalDigest(lifecycleSuccess.canonical),
      postRootChildCompletionCaptured: lifecycleSuccess.canonical.events.some((event, index) =>
        event.kind === 'agent_lifecycle' && event.state === 'completed'
        && index > lifecycleSuccess.canonical.events.findIndex(
          (candidate) => candidate.kind === 'turn_completed')),
      resolvedChildIdentities: lifecycleSuccess.canonical.agents
        .filter((agent) => agent.id !== 'root').map((agent) => agent.id),
      quiescentChildren: lifecycleSuccess.capture.quiescence.children.length,
      actualSteeringRequestsCaptured: lifecycleSuccess.capture.outboundRequests.length,
      roots: rootEvidence(lifecycleSuccess),
    },
    providerError: {
      canonicalDigest: canonicalDigest(lifecycleError.canonical),
      roots: rootEvidence(lifecycleError),
    },
    interrupted: {
      canonicalDigest: canonicalDigest(lifecycleInterrupted.canonical),
      roots: rootEvidence(lifecycleInterrupted),
    },
  },
  exactRoundTrips: {
    nestedDelegation: rootEvidence(nested),
    activityAndCompaction: rootEvidence(compaction),
  },
  prototypeValidity: {
    'A:vcon+agent_session': 'invalid-as-conformance: required Agent Session party metadata and dialog/trace parity are absent',
    'B:acr-vac': 'invalid-as-conformance: private entry vocabulary does not pass the pinned VAC CDDL',
    'C:canonical-graph': 'selected subset only: explicit legacy-sidecar and unrepresented-corpus dispositions remain format-review blockers',
  },
  stopGaps: [
    'root C does not yet map manual-title, artifact, tool permission/question, cancellation, or retry facts from a complete authoritative source',
    'sidecar adapter chronology across transcript and subagent sources is not yet canonicalized',
    'portable session identity is provisional; raw provider resume handles are excluded',
    '30 reviewed production workflow_update paths retain explicit not-yet-captured dispositions',
    'external prototype shape/conformance must be rebuilt or retained only as fit-gap evidence',
  ],
}

console.log(JSON.stringify(evidence, null, 2))
