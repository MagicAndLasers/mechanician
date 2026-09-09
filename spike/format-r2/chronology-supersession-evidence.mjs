// Deterministic successor evidence for bounded format-review checkpoint C1.4.
//
// The executable path intentionally refuses a dirty Mechanician source tree. Unit tests use the
// exported pure builder with injected repository metadata, which lets the contract be exercised
// while the implementation checkpoint is still in progress without ever minting authoritative-
// looking evidence for uncommitted bytes.
import crypto from 'node:crypto'
import fs from 'node:fs'
import path from 'node:path'
import { execFileSync } from 'node:child_process'
import { fileURLToPath } from 'node:url'

import {
  REVIEWED_CAPTURE_BASELINE_EXCLUSIONS,
  REVIEWED_CAPTURE_PRODUCTION_SOURCE_FIELDS,
  REVIEWED_SIDECAR_OBSERVED_FIELDS,
  REVIEWED_SIDECAR_PRODUCTION_FIELDS,
  auditReviewedCaptureSurface,
  canonicalDigest,
  classifySidecarField,
} from './canonical-field-contract.mjs'
import { canonicalFromSidecar } from './canonical-from-sidecar.mjs'
import { evidenceDeltaFromPredecessor } from './evidence-delta.mjs'
import { resolveFormatEvidenceRepository } from './external-evidence-repository.mjs'

export const C14_EVIDENCE_VERSION = 6
export const C14_ARTIFACT_FILENAME =
  'r2-chronology-supersession-coverage-2026-08-03.json'
export const C14_PREDECESSOR_FILENAME =
  'r2-interaction-safety-coverage-2026-08-03.json'
export const C14_PREDECESSOR_SHA256 =
  '8d1f5d0e4c97e6d6df613637a3a66c17b2a9f3fe84093e11a19111d6bb56363f'

// These paths are reviewed even when none of the four 2026-08-02 sanitized derivatives contains
// them. Keeping the list here as well as in the field oracle makes the v6 generator fail closed if
// a new durable C1.4 field is forgotten by the inventory it reports.
export const C14_REVIEWED_SIDECAR_FIELDS = Object.freeze([
  'captureOrdinalHighWatermark',
  'messages[].id',
  'messages[].captureOrdinal',
  'messages[].providerFrameUUID',
  'messages[].supersededByFrameUUID',
  'messages[].supersessionEventID',
  'messages[].supersededByEntryID',
  'messages[].supersessionCaptureOrdinal',
  'messages[].toolResultCaptureOrdinal',
  'messages[].toolTerminalCaptureOrdinal',
  'messages[].interactionResponseCaptureOrdinal',
  'messages[].interactionAcknowledgedCaptureOrdinal',
  'messages[].interactionClosure.captureOrdinal',
  'subagents.*.startedCaptureOrdinal',
  'subagents.*.endedCaptureOrdinal',
  'agentActivity[].captureOrdinal',
])

const CORE_CANONICAL_FIELDS = new Set([
  'messages[].id',
  'messages[].captureOrdinal',
  'messages[].supersessionEventID',
  'messages[].supersededByEntryID',
  'messages[].supersessionCaptureOrdinal',
  'messages[].toolResultCaptureOrdinal',
  'messages[].toolTerminalCaptureOrdinal',
  'messages[].interactionResponseCaptureOrdinal',
  'messages[].interactionAcknowledgedCaptureOrdinal',
  'messages[].interactionClosure.captureOrdinal',
])
const RAW_PROVIDER_HANDLE_FIELDS = new Set([
  'messages[].providerFrameUUID', 'messages[].supersededByFrameUUID',
])
const DERIVED_ORDER_FIELDS = new Set([
  'captureOrdinalHighWatermark',
  'subagents.*.startedCaptureOrdinal', 'subagents.*.endedCaptureOrdinal',
])
const KIND_AWARE_ACTIVITY_FIELDS = new Set(['agentActivity[].captureOrdinal'])

const here = path.dirname(fileURLToPath(import.meta.url))
const repo = path.resolve(here, '..', '..')

const sha256Bytes = (bytes) => crypto.createHash('sha256').update(bytes).digest('hex')
const sha256File = (file) => sha256Bytes(fs.readFileSync(file))
const countBy = (items, key) => Object.fromEntries(
  [...new Set(items.map((item) => item[key]))].sort().map((value) => [
    value, items.filter((item) => item[key] === value).length,
  ]),
)
const invariant = (condition, message) => {
  if (!condition) throw new Error(`C1.4 evidence invariant failed: ${message}`)
}

const WITHDRAWN_ASSISTANT_SENTINEL = 'WITHDRAWN_ASSISTANT_CONTENT_MUST_NOT_TRAVEL'
const RAW_TOOL_FRAME_HANDLE = 'RAW_PROVIDER_TOOL_FRAME_MUST_NOT_TRAVEL'
const RAW_REPLACEMENT_FRAME_HANDLE = 'RAW_PROVIDER_REPLACEMENT_FRAME_MUST_NOT_TRAVEL'
const USER_ENTRY_ID = '00000000-0000-4000-a000-000000000001'
const TOOL_ENTRY_ID = '00000000-0000-4000-a000-000000000002'
const REPLACEMENT_ENTRY_ID = '00000000-0000-4000-a000-000000000003'
const SUPERSESSION_EVENT_ID = '00000000-0000-4000-a000-000000000004'
const CHILD_SPAWN_ACTIVITY_ID = '00000000-0000-4000-a000-000000000005'
const CHILD_TERMINAL_ACTIVITY_ID = '00000000-0000-4000-a000-000000000006'

function completeFixture() {
  const sameObservedAt = '2026-08-03T20:00:00.000Z'
  const withdrawnAssistant = {
    kind: 'assistant', id: '00000000-0000-4000-a000-000000000099',
    text: WITHDRAWN_ASSISTANT_SENTINEL, observedAt: sameObservedAt, captureOrdinal: 4,
  }
  const messagesBeforeRetraction = [
    { kind: 'user', id: USER_ENTRY_ID, text: 'Run the deterministic fixture.',
      observedAt: sameObservedAt, captureOrdinal: 1 },
    { kind: 'tool', id: TOOL_ENTRY_ID, toolUseId: 'tool-local-1', toolName: 'Bash',
      text: 'printf fixture', toolResult: 'fixture result', toolIsError: false,
      observedAt: sameObservedAt, captureOrdinal: 2, toolResultCaptureOrdinal: 3,
      providerFrameUUID: RAW_TOOL_FRAME_HANDLE,
      supersededByFrameUUID: RAW_REPLACEMENT_FRAME_HANDLE,
      supersessionEventID: SUPERSESSION_EVENT_ID,
      supersededByEntryID: REPLACEMENT_ENTRY_ID,
      supersessionCaptureOrdinal: 8 },
    withdrawnAssistant,
    { kind: 'assistant', id: REPLACEMENT_ENTRY_ID, text: 'Replacement retained answer.',
      observedAt: sameObservedAt, captureOrdinal: 7 },
  ]
  // This is the persisted post-reducer shape. Production Swift tests own the reducer proof; this
  // fixture proves that its durable output cannot put withdrawn text back into a canonical record.
  const messages = messagesBeforeRetraction.filter((row) => row !== withdrawnAssistant)
  return {
    withdrawnAssistantWasPresentBeforeReducer: messagesBeforeRetraction.some(
      (row) => row.text === WITHDRAWN_ASSISTANT_SENTINEL),
    sidecar: {
      captureOrdinalHighWatermark: 9,
      messages,
      subagents: {
        'agent-local-1': {
          key: 'agent-local-1', subagentType: 'Explore', task: 'Late child',
          status: 'completed', resultPreview: 'Child finished after replacement.',
          startedAt: sameObservedAt, endedAt: sameObservedAt,
          // The tool result and child spawn share one observation batch. Lexical serialization is
          // deterministic, but the canonical contract deliberately asserts no causal order within it.
          startedCaptureOrdinal: 3, endedCaptureOrdinal: 9,
        },
      },
      // The append-only activity ledger owns lifecycle events. The mutable subagent summary above
      // only enriches these exact identity+ordinal boundaries and must not create duplicate truth.
      agentActivity: [{
        id: CHILD_SPAWN_ACTIVITY_ID, at: sameObservedAt, captureOrdinal: 3,
        turnID: 'turn-local-1', agentID: 'subagent:agent-local-1',
        kind: 'state', phase: 'model', agentLabel: 'Explore',
      }, {
        id: CHILD_TERMINAL_ACTIVITY_ID, at: sameObservedAt, captureOrdinal: 9,
        turnID: 'turn-local-1', agentID: 'subagent:agent-local-1',
        kind: 'state', phase: 'completed', agentLabel: 'Explore',
      }],
    },
  }
}

function degradedFixture() {
  return {
    subagents: {
      legacy: {
        key: 'legacy', subagentType: 'Explore', task: 'Legacy child', status: 'running',
        startedAt: '2026-08-03T20:00:00.000Z', startedCaptureOrdinal: 0,
      },
    },
    messages: [
      { kind: 'user', text: 'Missing stable identity and capture ordinal.' },
      { kind: 'assistant', id: '00000000-0000-4000-a000-000000000010',
        text: 'Partially upgraded row.', captureOrdinal: 2 },
    ],
  }
}

function sameOrdinalBatches(events) {
  const groups = new Map()
  for (const event of events) {
    if (!Number.isSafeInteger(event.captureOrdinal)) continue
    const batch = groups.get(event.captureOrdinal) ?? []
    batch.push(event.eventId)
    groups.set(event.captureOrdinal, batch)
  }
  return [...groups.entries()]
    .filter(([, eventIds]) => eventIds.length > 1)
    .map(([captureOrdinal, eventIds]) => ({ captureOrdinal, eventIds }))
}

export function chronologySupersessionProof() {
  const fixture = completeFixture()
  const complete = canonicalFromSidecar(fixture.sidecar)
  invariant(fixture.withdrawnAssistantWasPresentBeforeReducer,
    'the transition fixture must begin with withdrawn assistant content')
  invariant(!JSON.stringify(fixture.sidecar).includes(WITHDRAWN_ASSISTANT_SENTINEL),
    'the persisted post-reducer sidecar must exclude withdrawn assistant content')
  invariant(complete.chronology?.status === 'complete',
    'the fully ordinal fixture must have complete chronology')
  invariant(complete.chronology?.basis === 'record-local-capture-partial-order',
    'complete chronology must use the record-local partial-order basis')
  invariant(complete.chronology?.tieSemantics ===
      'same-ordinal-events-are-an-unordered-capture-batch',
  'equal capture ordinals must remain explicitly unordered')
  invariant(complete.chronology?.serializationOrder ===
      'capture-ordinal-then-stable-event-id',
  'serialization must be deterministic without inventing causality')

  const ordinals = complete.events.map((event) => event.captureOrdinal)
  invariant(ordinals.every((value) => Number.isSafeInteger(value) && value > 0),
    'every complete event must retain a positive capture ordinal')
  invariant(ordinals.every((value, index) => index === 0 || ordinals[index - 1] <= value),
    'complete events must serialize by nondecreasing capture ordinal')
  const batches = sameOrdinalBatches(complete.events)
  invariant(batches.some((batch) => batch.captureOrdinal === 3 && batch.eventIds.length === 2),
    'the complete fixture must exercise an unordered same-callback batch')

  const supersession = complete.events.find((event) => event.kind === 'supersession')
  invariant(supersession?.eventId === `supersession:${SUPERSESSION_EVENT_ID}`,
    'supersession must have a stable record-local event identity')
  invariant(supersession?.targetEventId === `entry:${TOOL_ENTRY_ID}`,
    'supersession must target the retained local tool event')
  invariant(supersession?.replacementEventId === `entry:${REPLACEMENT_ENTRY_ID}`,
    'supersession must identify the retained local replacement event')
  invariant(supersession?.captureOrdinal === 8,
    'supersession must retain its capture order')

  const retainedToolCall = complete.events.find((event) =>
    event.kind === 'tool_call' && event.eventId === `entry:${TOOL_ENTRY_ID}`)
  const retainedToolResult = complete.events.find((event) =>
    event.kind === 'tool_result' && event.eventId === `entry:${TOOL_ENTRY_ID}:result`)
  invariant(retainedToolCall != null && retainedToolResult != null,
    'a possibly executed superseded tool must retain its call and result evidence')
  const portable = JSON.stringify(complete)
  invariant(!portable.includes(WITHDRAWN_ASSISTANT_SENTINEL),
    'withdrawn assistant content must not reappear in the canonical record')
  invariant(!portable.includes(RAW_TOOL_FRAME_HANDLE)
      && !portable.includes(RAW_REPLACEMENT_FRAME_HANDLE),
  'raw provider frame handles must not enter canonical output')
  invariant(complete.events.filter((event) => event.kind === 'assistant_message').length === 1,
    'only the replacement assistant message may remain')

  const degraded = canonicalFromSidecar(degradedFixture())
  invariant(degraded.chronology?.status === 'degraded',
    'a partial/invalid ordinal fixture must be degraded')
  invariant(degraded.chronology?.basis === 'adapter-traversal-only',
    'degraded chronology must retain traversal without claiming time order')
  invariant(degraded.chronology?.diagnostic === 'cross-source-order-unavailable',
    'degraded chronology must carry the machine-readable diagnostic')
  invariant((degraded.chronology?.missingCaptureOrdinalEventCount ?? 0) > 0,
    'the degraded fixture must record missing ordinals')
  invariant((degraded.chronology?.invalidCaptureOrdinalEventCount ?? 0) > 0,
    'the degraded fixture must record invalid ordinals')
  invariant((degraded.chronology?.missingStableEventIdEventCount ?? 0) > 0,
    'the degraded fixture must record missing stable event identities')
  invariant(degraded.events.map((event) => event.kind).join(',') ===
      'agent_spawn,user_message,assistant_message',
  'partial ordinals must not reorder the degraded fixture')

  return {
    provenance: 'synthetic post-reducer sidecar shapes exercised through the production-seed canonical adapter; not live-provider proof',
    complete: {
      canonicalDigest: canonicalDigest(complete),
      chronology: complete.chronology,
      serializedEvents: complete.events.map((event) => ({
        captureOrdinal: event.captureOrdinal, eventId: event.eventId, kind: event.kind,
      })),
      unorderedCaptureBatches: batches,
      supersession: {
        eventId: supersession.eventId,
        targetEventId: supersession.targetEventId,
        replacementEventId: supersession.replacementEventId,
        captureOrdinal: supersession.captureOrdinal,
      },
      retainedToolEvidence: {
        callEventId: retainedToolCall.eventId,
        resultEventId: retainedToolResult.eventId,
        supersededButNotErased: true,
      },
      withdrawnAssistant: {
        presentBeforeReducer: true,
        absentFromPersistedSidecar: true,
        absentFromCanonicalRecord: true,
      },
      rawProviderHandlesExcluded: true,
    },
    degraded: {
      canonicalDigest: canonicalDigest(degraded),
      chronology: degraded.chronology,
      preservedTraversalKinds: degraded.events.map((event) => event.kind),
    },
  }
}

function assertC14FieldDispositions(dispositions) {
  const byPath = new Map(dispositions.map((item) => [item.path, item]))
  for (const pathName of C14_REVIEWED_SIDECAR_FIELDS) {
    const item = byPath.get(pathName)
    invariant(item != null, `reviewed sidecar field is absent from the oracle: ${pathName}`)
    if (CORE_CANONICAL_FIELDS.has(pathName)) {
      invariant(item.classification === 'canonical',
        `record-local identity/order field must be canonical: ${pathName}`)
    }
    if (RAW_PROVIDER_HANDLE_FIELDS.has(pathName)) {
      invariant(item.classification === 'intentionally-omitted',
        `raw provider handle must be intentionally omitted: ${pathName}`)
    }
    if (DERIVED_ORDER_FIELDS.has(pathName)) {
      invariant(item.classification === 'derived-projection',
        `summary/high-water ordering field must remain a derived projection: ${pathName}`)
    }
    if (KIND_AWARE_ACTIVITY_FIELDS.has(pathName)) {
      invariant(item.classification === 'not-yet-captured'
          && item.reason.includes('path-only'),
      `mixed activity path must retain its conservative kind-aware disposition: ${pathName}`)
    }
  }
}

export function currentOracleSnapshot() {
  const captureAudit = auditReviewedCaptureSurface()
  invariant(captureAudit.unclassified.length === 0,
    'reviewed capture surface contains unclassified paths')
  const productionSourceOnly = new Set(REVIEWED_CAPTURE_PRODUCTION_SOURCE_FIELDS)
  const captureEventItems = captureAudit.classified.filter((item) => item.eventType)
  const outboundItems = captureAudit.classified.filter((item) => item.outboundType)
  const envelopeItems = captureAudit.classified.filter(
    (item) => !item.eventType && !item.outboundType)
  const fixtureEmittedItems = captureEventItems.filter((item) => {
    if (item.eventType !== 'workflow_update') return true
    return !productionSourceOnly.has(item.path.slice('events[].event.'.length))
  })
  const captureEnvelopeItems = [...envelopeItems, ...outboundItems]
  const captureDispositions = countBy(captureAudit.classified, 'classification')

  const observedPaths = new Set(REVIEWED_SIDECAR_OBSERVED_FIELDS)
  const productionPaths = new Set(REVIEWED_SIDECAR_PRODUCTION_FIELDS)
  for (const field of C14_REVIEWED_SIDECAR_FIELDS) {
    if (!observedPaths.has(field)) productionPaths.add(field)
  }
  const observedDispositions = [...observedPaths].map(classifySidecarField)
  const productionDispositions = [...productionPaths].map(classifySidecarField)
  const c14Dispositions = C14_REVIEWED_SIDECAR_FIELDS.map(classifySidecarField)
  invariant([...observedDispositions, ...productionDispositions, ...c14Dispositions]
    .every((item) => item != null), 'reviewed sidecar surface contains unclassified paths')
  assertC14FieldDispositions(c14Dispositions)

  return {
    reviewedSidecarInventory: {
      observedCorpus: {
        paths: observedDispositions.length,
        dispositions: countBy(observedDispositions, 'classification'), unclassified: 0,
      },
      reviewedProductionSchemaOnly: {
        paths: productionDispositions.length,
        dispositions: countBy(productionDispositions, 'classification'), unclassified: 0,
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
    requiredC14FieldDispositions: c14Dispositions,
  }
}

function validateRuntime(runtime) {
  invariant(runtime?.source?.cleanTree === true,
    'evidence generation requires a clean Mechanician source tree')
  invariant(/^[0-9a-f]{40}$/.test(runtime.source.commit),
    'source commit must be one exact 40-character Git object id')
  invariant(runtime?.predecessor?.sha256 === C14_PREDECESSOR_SHA256,
    'predecessor digest does not match the reviewed C1.3 artifact')
  invariant(runtime?.predecessor?.document?.evidenceVersion === 5,
    'C1.4 predecessor must be evidence version 5')
  invariant(runtime?.predecessor?.relativePath?.endsWith(C14_PREDECESSOR_FILENAME),
    'C1.4 predecessor filename is incorrect')
  invariant(/^[0-9a-f]{64}$/.test(runtime?.corpusManifest?.sha256 ?? ''),
    'corpus manifest must have an exact SHA-256 digest')
  invariant(Array.isArray(runtime?.fixtures) && runtime.fixtures.length > 0,
    'at least one pinned synthetic fixture is required')
  invariant(runtime.fixtures.every((fixture) =>
    typeof fixture.path === 'string' && /^[0-9a-f]{64}$/.test(fixture.sha256)),
  'every fixture must carry a path and exact SHA-256 digest')
  assertC14FieldDispositions(runtime.oracle.requiredC14FieldDispositions)
}

export function buildChronologySupersessionEvidence(runtime) {
  validateRuntime(runtime)
  const relevantCases = Object.fromEntries(runtime.corpusManifest.document.cases
    .filter((item) => [4, 5, 7, 12].includes(item.id))
    .map((item) => [String(item.id), {
      status: item.status, fixtureRefs: item.fixtureRefs,
    }]))
  invariant(Object.keys(relevantCases).length === 4,
    'corpus manifest must expose cases 4, 5, 7, and 12')
  const proof = chronologySupersessionProof()
  const observedSidecarDispositions =
    runtime.oracle.reviewedSidecarInventory.observedCorpus.dispositions
  const captureDispositions = runtime.oracle.reviewedCaptureSurface.totalDispositions
  const productionSidecarPaths =
    runtime.oracle.reviewedSidecarInventory.reviewedProductionSchemaOnly.paths

  return {
    evidenceVersion: C14_EVIDENCE_VERSION,
    asOf: '2026-08-03',
    verdict: 'chronology-and-supersession-checkpoint-proven-format-review-blocked',
    predecessor: {
      path: runtime.predecessor.relativePath,
      sha256: runtime.predecessor.sha256,
      evidenceVersion: runtime.predecessor.document.evidenceVersion,
    },
    source: {
      repository: 'mechanician', commit: runtime.source.commit,
      cleanTree: runtime.source.cleanTree,
    },
    generation: {
      command: 'node spike/format-r2/chronology-supersession-evidence.mjs',
      deterministicFixtures: true,
    },
    verification: {
      requiredCommands: [
        'node --test spike/format-r2/test/chronology-supersession-evidence.test.mjs',
        'node --test spike/format-r2/test/*.test.mjs',
        './scripts/check.sh',
      ],
      resultsRecordedIn:
        'docs/mechanician/agent-document-format/format-review-completion-plan-2026-08-03.md',
      crossRepositoryDriftCheck:
        'regenerate twice and byte-compare after corpus-manifest pins are final',
    },
    fixtures: [...runtime.fixtures].sort((left, right) => left.path.localeCompare(right.path)),
    sanitizedCorpusManifest: {
      path: runtime.corpusManifest.relativePath,
      sha256: runtime.corpusManifest.sha256,
    },
    reviewedSidecarInventory: runtime.oracle.reviewedSidecarInventory,
    reviewedCaptureSurface: runtime.oracle.reviewedCaptureSurface,
    requiredC14FieldDispositions: runtime.oracle.requiredC14FieldDispositions,
    deltaFromPredecessor: evidenceDeltaFromPredecessor({
      observedSidecarDispositions,
      captureDispositions,
      separatelyReviewedProductionSidecarPaths: productionSidecarPaths,
    }, runtime.predecessor.document),
    chronologyAndSupersession: proof,
    corpusCases: relevantCases,
    prototypeValidity: {
      'A:vcon+agent_session':
        'fit-gap projection only; chronology and supersession require declared extension members',
      'B:acr-vac':
        'fit-gap projection only; private entry vocabulary still does not pass pinned VAC CDDL',
      'C:canonical-graph':
        'selected subset with complete new-record partial order and explicit legacy degradation; the formal format review remains blocked',
    },
    stopGaps: [
      'the provider-neutral source exposes no tool/child retry relationship and the canonical model does not fabricate one',
      'result-less stopped legacy tools are local reconciliation facts, not provider-observed cancellation',
      'legacy and partially ordinal sidecars retain an explicit degraded chronology diagnostic',
      'portable session identity, artifacts, disclosure profiles, lineage/amendment and C2/C3 evidence remain open',
      '30 reviewed production workflow_update paths retain explicit not-yet-captured dispositions',
    ],
  }
}

export function runtimeFromRepositories() {
  const externalEvidence = resolveFormatEvidenceRepository()
  const predecessorPath = path.join(
    externalEvidence.evidenceDirectory, C14_PREDECESSOR_FILENAME)
  const corpusManifestPath = path.join(
    externalEvidence.evidenceDirectory, 'corpus-manifest.json')
  const sourceCommit = execFileSync('git', ['rev-parse', 'HEAD'], {
    cwd: repo, encoding: 'utf8', stdio: ['ignore', 'pipe', 'inherit'],
  }).trim()
  const sourceTreeClean = execFileSync('git', ['status', '--porcelain'], {
    cwd: repo, encoding: 'utf8', stdio: ['ignore', 'pipe', 'inherit'],
  }).trim() === ''
  if (!sourceTreeClean) {
    throw new Error('chronology/supersession evidence requires a clean Mechanician source tree')
  }
  const predecessorBytes = fs.readFileSync(predecessorPath)
  const corpusManifestBytes = fs.readFileSync(corpusManifestPath)
  const fixturePaths = [
    fileURLToPath(import.meta.url),
    path.join(repo, 'agentd', 'test', 'fixtures', 'nested-delegation-fixture.mjs'),
    path.join(repo, 'agentd', 'test', 'fixtures',
      'format-review-interaction-lifecycle-fixture.mjs'),
  ]
  return {
    source: { commit: sourceCommit, cleanTree: sourceTreeClean },
    predecessor: {
      relativePath: path.relative(externalEvidence.repositoryRoot, predecessorPath),
      sha256: sha256Bytes(predecessorBytes),
      document: JSON.parse(predecessorBytes),
    },
    corpusManifest: {
      relativePath: path.relative(externalEvidence.repositoryRoot, corpusManifestPath),
      sha256: sha256Bytes(corpusManifestBytes),
      document: JSON.parse(corpusManifestBytes),
    },
    fixtures: fixturePaths.map((fixture) => ({
      path: path.relative(repo, fixture), sha256: sha256File(fixture),
    })),
    oracle: currentOracleSnapshot(),
  }
}

const invokedPath = process.argv[1] == null ? null : path.resolve(process.argv[1])
if (invokedPath === fileURLToPath(import.meta.url)) {
  const evidence = buildChronologySupersessionEvidence(runtimeFromRepositories())
  process.stdout.write(`${JSON.stringify(evidence, null, 2)}\n`)
}
