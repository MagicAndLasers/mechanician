// Reproducible successor evidence for the bounded format-review interaction/failure checkpoint.
// Generate only from a clean Mechanician source commit; the external evidence checkout may be
// dirty because its corpus manifest must first pin that exact source commit.
import crypto from 'node:crypto'
import fs from 'node:fs'
import path from 'node:path'
import { execFileSync } from 'node:child_process'
import { fileURLToPath } from 'node:url'
import {
  REVIEWED_CAPTURE_BASELINE_EXCLUSIONS,
  REVIEWED_CAPTURE_PRODUCTION_SOURCE_FIELDS,
  REVIEWED_CAPTURE_SOURCE_PINS,
  REVIEWED_SIDECAR_OBSERVED_FIELDS,
  REVIEWED_SIDECAR_PRODUCTION_FIELDS,
  auditReviewedCaptureSurface,
  canonicalDigest,
  classifySidecarField,
} from './canonical-field-contract.mjs'
import { canonicalFromSidecar } from './canonical-from-sidecar.mjs'
import { captureTurn } from './capture.mjs'
import { evidenceDeltaFromPredecessor } from './evidence-delta.mjs'
import { resolveFormatEvidenceRepository } from './external-evidence-repository.mjs'
import {
  interactionCaptureOptions, interactionObservedAtForSequence,
} from './interaction-fixture-plan.mjs'
import { runComparison } from './run.mjs'

const here = path.dirname(fileURLToPath(import.meta.url))
const repo = path.resolve(here, '..', '..')
const externalEvidence = resolveFormatEvidenceRepository()
const evidenceRepository = externalEvidence.repositoryRoot
const evidenceDirectory = externalEvidence.evidenceDirectory
const predecessorPath = path.join(
  evidenceDirectory, 'r2-interaction-lifecycle-coverage-2026-08-03.json')
const corpusManifestPath = path.join(evidenceDirectory, 'corpus-manifest.json')
const fixturePath = (name) => path.join(repo, 'agentd', 'test', 'fixtures', name)
const sha256Bytes = (bytes) => crypto.createHash('sha256').update(bytes).digest('hex')
const sha256File = (file) => sha256Bytes(fs.readFileSync(file))
const countBy = (items, key) => Object.fromEntries(
  [...new Set(items.map((item) => item[key]))].sort().map((value) => [
    value, items.filter((item) => item[key] === value).length,
  ]),
)
const rootEvidence = (run) => Object.fromEntries(
  Object.entries(run.results.roots).map(([root, result]) => [root, {
    digest: result.digest,
    structuralMisses: result.structuralMisses.length,
    fieldDifferences: result.differences.length,
    declaredPrototypeGaps: result.declaredPrototypeGaps.length,
    unclassifiedDifferences: result.unclassifiedDifferences.length,
  }]),
)
const errorMessage = async (operation) => {
  try {
    await operation()
    return null
  } catch (error) {
    return error instanceof Error ? error.message : String(error)
  }
}

const sourceCommit = execFileSync('git', ['rev-parse', 'HEAD'], {
  cwd: repo, encoding: 'utf8', stdio: ['ignore', 'pipe', 'inherit'],
}).trim()
const sourceTreeClean = execFileSync('git', ['status', '--porcelain'], {
  cwd: repo, encoding: 'utf8', stdio: ['ignore', 'pipe', 'inherit'],
}).trim() === ''
if (!sourceTreeClean) throw new Error('interaction evidence requires a clean Mechanician source tree')

const predecessor = JSON.parse(fs.readFileSync(predecessorPath, 'utf8'))
const corpusManifest = JSON.parse(fs.readFileSync(corpusManifestPath, 'utf8'))
const fixtureNames = [
  'minimal-conversation-fixture.mjs',
  'nested-delegation-fixture.mjs',
  'activity-agents-compaction-fixture.mjs',
  'format-review-lifecycle-fixture.mjs',
  'format-review-interaction-lifecycle-fixture.mjs',
]
const fixtures = fixtureNames.map((name) => ({
  path: path.relative(repo, fixturePath(name)), sha256: sha256File(fixturePath(name)),
}))

const captureAudit = auditReviewedCaptureSurface()
if (captureAudit.unclassified.length) throw new Error('reviewed capture surface is unclassified')
const captureEventItems = captureAudit.classified.filter((item) => item.eventType)
const outboundItems = captureAudit.classified.filter((item) => item.outboundType)
const envelopeItems = captureAudit.classified.filter(
  (item) => !item.eventType && !item.outboundType)
const productionSourceOnly = new Set(REVIEWED_CAPTURE_PRODUCTION_SOURCE_FIELDS)
const fixtureEmittedItems = captureEventItems.filter((item) => {
  if (item.eventType !== 'workflow_update') return true
  return !productionSourceOnly.has(item.path.slice('events[].event.'.length))
})
const captureEnvelopeItems = [...envelopeItems, ...outboundItems]
const captureDispositions = countBy(captureAudit.classified, 'classification')
const sidecarObservedDispositions = REVIEWED_SIDECAR_OBSERVED_FIELDS.map(classifySidecarField)
const sidecarProductionDispositions = REVIEWED_SIDECAR_PRODUCTION_FIELDS.map(classifySidecarField)
if ([...sidecarObservedDispositions, ...sidecarProductionDispositions].some((item) => !item)) {
  throw new Error('reviewed sidecar surface is unclassified')
}

const interaction = await runComparison(
  fixturePath('format-review-interaction-lifecycle-fixture.mjs'), interactionCaptureOptions())
const portableInteraction = JSON.stringify(interaction.canonical)
const privateOrOperativeValuesExcluded = [
  '/Users/private/Outside/result.txt', '/Users/private/Workspace',
  '/Users/private/OrdinaryPermission/secret.txt', 'permission-write-escape',
  'permission-capability', 'write-response-1', 'capability-response-1',
  'question-output-style', 'question-response-1', 'interrupt-root-1',
].every((value) => !portableInteraction.includes(value))

const sidecarCanonical = canonicalFromSidecar({
  messages: [{
    kind: 'permission', permissionId: 'PRIVATE-PENDING-PERMISSION', permName: 'Bash',
    text: '/Users/private/Legacy/secret-command', permDecided: false,
  }, {
    kind: 'permission', permissionId: 'PRIVATE-DECIDED-PERMISSION', permName: 'Bash',
    text: '/Users/private/Legacy/approved-command', permDecided: true,
    permAllowed: true, permAlways: false,
    interactionResponseStatus: 'accepted',
    interactionResponseObservedAt: '2026-08-03T18:00:01.000Z',
    interactionAcknowledgedAt: '2026-08-03T18:00:02.000Z',
  }, {
    kind: 'permission', permissionId: 'PRIVATE-CLOSED-PERMISSION', permName: 'Read',
    text: '/Users/private/Legacy/unanswered-command', permDecided: false,
    interactionClosure: {
      outcome: 'cancelled', reason: 'turn_interrupted',
      observedAt: '2026-08-03T18:00:03.000Z',
    },
  }, {
    kind: 'question', questionId: 'PRIVATE-PENDING-QUESTION', questionDecided: false,
    questions: [{ question: 'Pending?', options: [] }],
  }, {
    kind: 'question', questionId: 'PRIVATE-ANSWERED-QUESTION', questionDecided: true,
    questions: [{ question: 'Retain?', options: [{ label: 'Yes' }] }],
    questionAnswers: { 'Retain?': 'Yes' },
    questionFreeTextResponse: 'Retained free text',
    interactionResponseStatus: 'accepted',
    interactionResponseObservedAt: '2026-08-03T18:00:04.000Z',
    interactionAcknowledgedAt: '2026-08-03T18:00:05.000Z',
  }, {
    kind: 'question', questionId: 'PRIVATE-CLOSED-QUESTION', questionDecided: false,
    questions: [{ question: 'Closed pending?', options: [] }],
    interactionClosure: {
      outcome: 'cancelled', reason: 'turn_interrupted',
      observedAt: '2026-08-03T18:00:06.000Z',
    },
  }, {
    kind: 'tool', toolUseId: 'failed-tool', toolName: 'Bash',
    toolResult: 'exit 1', toolIsError: true,
  }, {
    kind: 'tool', toolUseId: 'stopped-tool', toolName: 'Bash', toolState: 'stopped',
  }],
  subagents: {
    failed: { key: 'failed', status: 'failed', subagentType: 'Explore', task: 'fail' },
    stopped: { key: 'stopped', status: 'stopped', subagentType: 'Explore', task: 'stop' },
  },
})
const sidecarPortable = JSON.stringify(sidecarCanonical)

const closedPendingRuns = {}
for (const plan of [{
  key: 'permission', prompt: 'pending-permission', requestEvent: 'permission_request',
  requestField: 'permissionId', requestId: 'permission-left-pending',
}, {
  key: 'question', prompt: 'pending-question', requestEvent: 'question_request',
  requestField: 'reqId', requestId: 'question-left-pending',
}]) {
  const run = await runComparison(fixturePath('format-review-interaction-lifecycle-fixture.mjs'), {
    prompt: plan.prompt, observedAtForSequence: interactionObservedAtForSequence,
    requireQuiescence: true,
    interruptRequests: [{
      id: `interrupt-${plan.key}`,
      after: { type: plan.requestEvent, [plan.requestField]: plan.requestId },
    }],
  })
  const eventTypes = run.capture.events.map(({ event }) => event.type)
  const closure = run.canonical.events.find((event) => event.kind === 'interaction_closed')
  closedPendingRuns[plan.key] = {
    rootInterrupted: run.capture.quiescence.root.interrupted,
    closureBeforeTerminal:
      eventTypes.indexOf('interaction_closed') < eventTypes.indexOf('done'),
    closure: closure ? {
      interactionId: closure.interactionId, interactionType: closure.interactionType,
      outcome: closure.outcome, reason: closure.reason,
    } : null,
    responseFabricated: run.canonical.events.some((event) =>
      ['authorization_response', 'answer'].includes(event.kind)),
    roots: rootEvidence(run),
  }
}

const pendingFailures = {
  unacknowledgedResponse: await errorMessage(() => captureTurn(
    fixturePath('format-review-interaction-lifecycle-fixture.mjs'), {
      prompt: 'unacked-permission', observedAtForSequence: interactionObservedAtForSequence,
      requireQuiescence: true,
      permissionResponses: [{
        permissionId: 'permission-unacknowledged', responseId: 'unacked-response',
        allow: true, always: false,
      }],
    })),
}

const relevantCases = Object.fromEntries(corpusManifest.cases
  .filter((item) => [5, 7, 12].includes(item.id))
  .map((item) => [String(item.id), {
    status: item.status, fixtureRefs: item.fixtureRefs,
  }]))

const evidence = {
  evidenceVersion: 5,
  asOf: '2026-08-03',
  verdict: 'interaction-and-failure-checkpoint-proven-format-review-blocked',
  predecessor: {
    path: path.relative(evidenceRepository, predecessorPath), sha256: sha256File(predecessorPath),
    evidenceVersion: predecessor.evidenceVersion,
  },
  source: { repository: 'mechanician', commit: sourceCommit, cleanTree: sourceTreeClean },
  generation: {
    command: 'node spike/format-r2/interaction-evidence.mjs', deterministicClock: true,
  },
  verification: {
    requiredCommands: [
      'node --test spike/format-r2/test/*.test.mjs', './scripts/check.sh',
    ],
    resultsRecordedIn: 'docs/mechanician/agent-document-format/format-review-completion-plan-2026-08-03.md',
    crossRepositoryDriftCheck: 'separate required verification after this JSON is checked in',
  },
  dogfood: {
    status: 'pending-post-generation packaging; exact source stamp is recorded in the completion note',
    sourceStamp: null,
  },
  fixtures,
  sanitizedCorpusManifest: {
    path: path.relative(evidenceRepository, corpusManifestPath), sha256: sha256File(corpusManifestPath),
  },
  reviewedSidecarInventory: {
    observedCorpus: {
      paths: sidecarObservedDispositions.length,
      dispositions: countBy(sidecarObservedDispositions, 'classification'), unclassified: 0,
    },
    reviewedProductionSchemaOnly: {
      paths: sidecarProductionDispositions.length,
      dispositions: countBy(sidecarProductionDispositions, 'classification'), unclassified: 0,
    },
  },
  reviewedCaptureSurface: {
    reviewedPaths: captureAudit.classified.length,
    fixtureEmitted: {
      paths: fixtureEmittedItems.length,
      dispositions: countBy(fixtureEmittedItems, 'classification'),
    },
    captureEnvelope: {
      paths: captureEnvelopeItems.length,
      dispositions: countBy(captureEnvelopeItems, 'classification'),
      envelopePaths: envelopeItems.length, outboundRequestPaths: outboundItems.length,
    },
    productionSourceOnly: {
      paths: captureEventItems.length - fixtureEmittedItems.length,
      dispositions: countBy(captureEventItems.filter(
        (item) => !fixtureEmittedItems.includes(item)), 'classification'),
    },
    totalDispositions: captureDispositions,
    normalBaselineReachablePaths:
      captureAudit.classified.length - REVIEWED_CAPTURE_BASELINE_EXCLUSIONS.size,
    variantOrPostTerminalPaths: REVIEWED_CAPTURE_BASELINE_EXCLUSIONS.size,
    unclassified: 0,
  },
  deltaFromPredecessor: evidenceDeltaFromPredecessor({
    observedSidecarDispositions: countBy(sidecarObservedDispositions, 'classification'),
    captureDispositions,
    separatelyReviewedProductionSidecarPaths: sidecarProductionDispositions.length,
  }, predecessor),
  interactionLifecycleCapture: {
    fixture: 'agentd/test/fixtures/format-review-interaction-lifecycle-fixture.mjs',
    provenance: 'synthetic provider-neutral wire fixture; not production-provider execution proof',
    canonicalDigest: canonicalDigest(interaction.canonical),
    capturedWireEvents: interaction.capture.events.length,
    capturedOutboundRequests: interaction.capture.outboundRequests.length,
    canonicalAgents: interaction.canonical.agents.length,
    canonicalEvents: interaction.canonical.events.length,
    privateOrOperativeValuesExcluded,
    replayedDecisionDeliveryAttempts: interaction.canonical.events.find(
      (event) => event.kind === 'authorization_response'
        && event.interactionId === 'authorization-1')?.deliveryAttempts ?? null,
    terminalOutcomes: interaction.canonical.events
      .filter((event) => ['tool_result', 'agent_lifecycle', 'turn_stopped'].includes(event.kind))
      .map((event) => ({ kind: event.kind, state: event.state ?? null,
        outcome: event.outcome ?? (event.kind === 'turn_stopped' ? 'stopped' : null) })),
    roots: rootEvidence(interaction),
  },
  sidecarInteractionLifecycle: {
    canonicalDigest: canonicalDigest(sidecarCanonical),
    privateOrOperativeValuesExcluded: [
      'PRIVATE-PENDING-PERMISSION', 'PRIVATE-DECIDED-PERMISSION',
      'PRIVATE-CLOSED-PERMISSION', 'PRIVATE-PENDING-QUESTION',
      'PRIVATE-ANSWERED-QUESTION', 'PRIVATE-CLOSED-QUESTION',
      '/Users/private/Legacy/secret-command', '/Users/private/Legacy/approved-command',
      '/Users/private/Legacy/unanswered-command',
    ].every((value) => !sidecarPortable.includes(value)),
    mappedKinds: countBy(sidecarCanonical.events, 'kind'),
    responseStatuses: sidecarCanonical.events
      .filter((event) => event.responseStatus)
      .map((event) => ({ kind: event.kind, status: event.responseStatus })),
    closureFacts: sidecarCanonical.events
      .filter((event) => event.kind === 'interaction_closed')
      .map((event) => ({ interactionType: event.interactionType,
        outcome: event.outcome, reason: event.reason, observedAt: event.observedAt })),
    retainedQuestionFreeText: sidecarCanonical.events.find(
      (event) => event.kind === 'answer')?.response ?? null,
  },
  pendingInteractionClosure: closedPendingRuns,
  failClosedChecks: { unacknowledgedResponse: pendingFailures.unacknowledgedResponse },
  corpusCases: relevantCases,
  prototypeValidity: {
    'A:vcon+agent_session': 'fit-gap projection only; interaction and lifecycle facts require declared extension members',
    'B:acr-vac': 'fit-gap projection only; private entry vocabulary still does not pass pinned VAC CDDL',
    'C:canonical-graph': 'selected subset with zero unclassified reviewed fields; the formal format review remains blocked',
  },
  stopGaps: [
    'the provider-neutral source exposes no tool/child retry relationship and the canonical model does not fabricate one',
    'result-less stopped legacy tools are local reconciliation facts, not provider-observed cancellation',
    'retraction remains unrepresented',
    'sidecar chronology across transcript and subagent sources is not yet canonicalized',
    'portable session identity, artifacts, disclosure profiles, lineage/amendment and C2/C3 evidence remain open',
    '30 reviewed production workflow_update paths retain explicit not-yet-captured dispositions',
  ],
}

console.log(JSON.stringify(evidence, null, 2))
