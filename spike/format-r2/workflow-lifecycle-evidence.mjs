// Deterministic successor evidence for bounded format-review checkpoint C1.5.
//
// The executable path refuses dirty Mechanician source. Tests exercise the pure builder and proof
// collector with injected repository metadata, so an uncommitted spike can never mint an
// authoritative-looking artifact.
import crypto from 'node:crypto'
import fs from 'node:fs'
import path from 'node:path'
import { execFileSync } from 'node:child_process'
import { fileURLToPath } from 'node:url'

import {
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
import { runComparison } from './run.mjs'
import { toCanonical } from './canonical.mjs'

export const C15_EVIDENCE_VERSION = 7
export const C15_ARTIFACT_FILENAME =
  'r2-workflow-lifecycle-coverage-2026-08-03.json'
export const C15_PREDECESSOR_FILENAME =
  'r2-chronology-supersession-coverage-2026-08-03.json'
export const C15_PREDECESSOR_SHA256 =
  '9e8c894313e0891a81a9543b9fe1b2357c34a8a52f04f534a629e3b210c724f9'
export const C15_FIXTURE_SHA256 =
  'eb2f8026f3f1d2ef165e00f5f7c8ce374240f559a6c1409fe08aad34df8c46e1'

const here = path.dirname(fileURLToPath(import.meta.url))
const repo = path.resolve(here, '..', '..')
const workflowFixturePath = path.join(
  repo, 'agentd', 'test', 'fixtures', 'format-review-workflow-lifecycle-fixture.mjs')

const sha256Bytes = (bytes) => crypto.createHash('sha256').update(bytes).digest('hex')
const sha256File = (file) => sha256Bytes(fs.readFileSync(file))
const invariant = (condition, message) => {
  if (!condition) throw new Error('C1.5 evidence invariant failed: ' + message)
}
const countByClassification = (items) => Object.fromEntries(
  [...new Set(items.map((item) => item.classification))].sort().map((classification) => [
    classification,
    items.filter((item) => item.classification === classification).length,
  ]),
)

export function currentWorkflowOracleSnapshot() {
  const capture = auditReviewedCaptureSurface()
  const observed = REVIEWED_SIDECAR_OBSERVED_FIELDS.map(classifySidecarField)
  const production = REVIEWED_SIDECAR_PRODUCTION_FIELDS.map(classifySidecarField)
  const workflowSourcePaths = new Set(REVIEWED_CAPTURE_PRODUCTION_SOURCE_FIELDS)
  const workflowCapture = capture.classified.filter((item) =>
    item.eventType === 'workflow_update'
      && workflowSourcePaths.has(item.path.replace(/^events\[\]\.event\./, '')))
  return {
    reviewedSidecarInventory: {
      observedCorpus: {
        paths: observed.length,
        dispositions: countByClassification(observed),
        unclassified: observed.filter((item) => item == null).length,
      },
      reviewedProductionSchemaOnly: {
        paths: production.length,
        dispositions: countByClassification(production),
        unclassified: production.filter((item) => item == null).length,
      },
    },
    reviewedCaptureSurface: {
      reviewedPaths: capture.classified.length,
      totalDispositions: countByClassification(capture.classified),
      unclassified: capture.unclassified.length,
      workflowProductionSourceOnly: {
        paths: workflowCapture.length,
        dispositions: countByClassification(workflowCapture),
      },
    },
  }
}

function rootProof(run) {
  return Object.fromEntries(Object.entries(run.results.roots).map(([root, result]) => [
    root,
    {
      structuralMisses: result.structuralMisses.length,
      fieldDifferences: result.differences.length,
      declaredPrototypeGaps: result.declaredPrototypeGaps.length,
      unclassifiedDifferences: result.unclassifiedDifferences.length,
      extensionDependence: result.extensions.filter((item) => item.includes('workflow')).length,
    },
  ]))
}

function lifecycleRefinementProof() {
  const observedAt = '2026-08-03T22:30:00.000Z'
  const capture = {
    prompt: 'Prove terminal refinement.',
    promptObservedAt: observedAt,
    producer: { name: 'Mechanician evidence', version: '0.23.0', build: '207' },
    profile: { id: 'ai.mechanician.conversation-record.native-graph', version: '0-spike' },
    events: [
      { type: 'turn_started', id: 'RAW-TURN' },
      {
        type: 'workflow_update', id: 'RAW-TURN', taskId: 'RAW-TASK',
        toolUseId: 'RAW-TOOL', taskType: 'local_workflow', isWorkflowRun: true,
        workflowName: 'Terminal proof', status: 'completed',
        workflowProgress: [{
          type: 'workflow_phase', index: 0, title: 'Verify', state: 'completed',
        }, {
          type: 'workflow_agent', index: 0, phaseIndex: 0, label: 'Verifier',
          agentId: 'RAW-AGENT', state: 'done',
        }],
      },
      {
        type: 'workflow_update', id: 'RAW-TURN', taskId: 'RAW-TASK',
        status: 'failed', error: 'Authoritative failure',
        workflowProgress: [{
          type: 'workflow_phase', index: 0, title: 'Verify', state: 'failed',
        }, {
          type: 'workflow_agent', index: 0, phaseIndex: 0, label: 'Verifier',
          agentId: 'RAW-AGENT-ROTATED', state: 'error', error: 'Child failed',
        }],
      },
      {
        type: 'workflow_update', id: 'RAW-TURN', taskId: 'RAW-TASK',
        status: 'running', workflowProgress: [{
          type: 'workflow_agent', index: 0, phaseIndex: 0, label: 'Verifier',
          agentId: 'RAW-AGENT-LATE', state: 'progress',
        }],
      },
    ].map((event, index) => ({ seq: index + 1, observedAt, event })),
  }
  const canonical = toCanonical(capture)
  const workflowStates = canonical.events
    .filter((event) => event.kind === 'workflow_lifecycle')
    .map((event) => ({
      state: event.state,
      reportedState: event.reportedState,
      provenance: event.stateProvenance,
    }))
  const childStates = canonical.events
    .filter((event) => event.kind === 'agent_lifecycle'
      && event.lifecycleScope === 'workflow-progress')
    .map((event) => ({
      state: event.state,
      reportedState: event.reportedState,
      provenance: event.stateProvenance,
    }))
  return {
    workflowStates,
    childStates,
    workflowAgentCount: canonical.agents
      .filter((agent) => agent.type === 'workflow-agent').length,
    rawAliasesExcluded: !/RAW-(?:TURN|TASK|TOOL|AGENT)/.test(JSON.stringify(canonical)),
  }
}

function sidecarProof() {
  const exactIdentity = 'workflow:RAW-RUN:0:0'
  const canonical = canonicalFromSidecar({
    workflowRuns: {
      RAW_STORAGE: {
        runKey: 'RAW-RUN', sessionId: 'RAW-SESSION', runTaskId: 'RAW-TASK',
        toolUseId: 'RAW-TOOL', outputFile: '/Users/private/output.json',
        workflowName: 'Sidecar proof', description: 'One exact and one degraded child',
        status: 'failed', phases: { raw: { index: 0, title: 'Verify' } },
        agents: {
          '0:0': {
            index: 0, phaseIndex: 0, phaseTitle: 'Verify', label: 'Exact',
            state: 'done', agentId: 'RAW-PROVIDER-AGENT',
          },
          '0:1': {
            index: 1, phaseIndex: 0, phaseTitle: 'Verify', label: 'Degraded',
            state: 'failed', agentId: 'RAW-PROVIDER-AGENT-2', error: 'Synthetic failure',
          },
        },
      },
    },
    agentActivity: [{
      id: 'exact-start', captureOrdinal: 1, agentID: exactIdentity,
      kind: 'state', phase: 'model', at: '2026-08-03T22:40:00.000Z',
    }, {
      id: 'exact-end', captureOrdinal: 2, agentID: exactIdentity,
      kind: 'state', phase: 'completed', at: '2026-08-03T22:40:01.000Z',
    }],
  })
  const workflowAgents = canonical.agents.filter((agent) => agent.type === 'workflow-agent')
  return {
    workflows: canonical.workflows?.length ?? 0,
    phases: canonical.workflowPhases?.length ?? 0,
    workflowAgents: workflowAgents.length,
    exactLifecycleEvents: canonical.events.filter((event) =>
      event.stateProvenance === 'persisted-agent-activity-state').length,
    degradedLifecycleEvents: canonical.events.filter((event) =>
      event.stateProvenance ===
        'degraded-workflow-summary-without-event-ledger-match').length,
    chronology: canonical.chronology.status,
    rawAndPrivateLocatorsExcluded:
      !/RAW-(?:RUN|SESSION|TASK|TOOL|PROVIDER)|\/Users\/private/.test(
        JSON.stringify(canonical)),
  }
}

export async function collectWorkflowLifecycleProof(
  fixturePath = workflowFixturePath,
) {
  const run = await runComparison(fixturePath, {
    prompt: 'Capture the workflow lifecycle.',
    promptObservedAt: '2026-08-03T21:59:59.000Z',
    observedAtForSequence: (sequence) =>
      new Date(Date.UTC(2026, 7, 3, 22, 0, sequence)).toISOString(),
    requireQuiescence: true,
  })
  const canonicalText = JSON.stringify(run.canonical)
  const rootCompletedIndex = run.canonical.events.findIndex(
    (event) => event.kind === 'turn_completed')
  const terminalIndex = run.canonical.events.findIndex(
    (event) => event.kind === 'workflow_lifecycle' && event.state === 'failed')
  const childLifecycle = run.canonical.events.filter((event) =>
    event.kind === 'agent_lifecycle' && event.lifecycleScope === 'workflow-progress')
  const workflowTools = run.canonical.events.filter((event) =>
    event.kind === 'agent_tool_observation' && event.workflowId != null)
  return {
    fixture: path.relative(repo, fixturePath),
    canonicalDigest: canonicalDigest(run.canonical),
    capturedWireEvents: run.capture.events.length,
    quiescentChildren: run.capture.quiescence.children,
    graph: {
      workflows: run.canonical.workflows?.length ?? 0,
      phases: run.canonical.workflowPhases?.length ?? 0,
      workflowAgents: run.canonical.agents
        .filter((agent) => agent.type === 'workflow-agent').length,
      workflowOwnerIsNestedAgent:
        run.canonical.workflows?.[0]?.ownerAgentId !== 'root',
      workflowPhaseLinked:
        run.canonical.workflowPhases?.[0]?.workflowId
          === run.canonical.workflows?.[0]?.id,
    },
    postRootTerminalCaptured:
      rootCompletedIndex >= 0 && terminalIndex > rootCompletedIndex,
    terminalMonotonicity: {
      terminalState: childLifecycle.at(-1)?.state ?? null,
      staleReportedState: childLifecycle.at(-1)?.reportedState ?? null,
      provenance: childLifecycle.at(-1)?.stateProvenance ?? null,
    },
    repeatedIdenticalToolObservations:
      workflowTools.filter((event) =>
        event.name === 'Bash' && event.toolTarget === 'fixture command').length,
    rawAndPrivateFieldsExcluded:
      !/PRIVATE-PROVIDER-AGENT|\/Users\/private\/Workflow|workflow-task|workflow-tool/.test(
        canonicalText),
    roots: rootProof(run),
    terminalRefinement: lifecycleRefinementProof(),
    legacySidecar: sidecarProof(),
  }
}

function validateRuntime(runtime) {
  invariant(runtime?.source?.cleanTree === true, 'source tree must be clean')
  invariant(/^[0-9a-f]{40}$/.test(runtime?.source?.commit ?? ''),
    'source commit must be one exact Git object')
  invariant(runtime?.predecessor?.sha256 === C15_PREDECESSOR_SHA256,
    'predecessor digest changed')
  invariant(runtime?.predecessor?.document?.evidenceVersion === 6,
    'predecessor must be evidence version 6')
  invariant(runtime?.fixture?.sha256 === C15_FIXTURE_SHA256,
    'workflow fixture digest changed')
  invariant(/^[0-9a-f]{64}$/.test(runtime?.corpusManifest?.sha256 ?? ''),
    'corpus manifest must have an exact digest')
  invariant(runtime?.oracle?.reviewedCaptureSurface?.unclassified === 0,
    'capture oracle has unclassified paths')
  invariant(runtime?.oracle?.reviewedSidecarInventory?.observedCorpus?.unclassified === 0,
    'observed sidecar oracle has unclassified paths')
  invariant(runtime?.oracle?.reviewedSidecarInventory
    ?.reviewedProductionSchemaOnly?.unclassified === 0,
  'production sidecar oracle has unclassified paths')
  invariant(
    runtime.oracle.reviewedCaptureSurface.totalDispositions['not-yet-captured'] == null,
    'reviewed capture surface still has not-yet-captured paths')
  for (const [root, result] of Object.entries(runtime.proof.roots)) {
    invariant(result.structuralMisses === 0, root + ' has structural misses')
    invariant(result.unclassifiedDifferences === 0, root + ' has unclassified differences')
    if (root !== 'C:canonical-graph') {
      invariant(result.extensionDependence > 0,
        root + ' did not declare its workflow extension dependence')
    }
  }
  invariant(runtime.proof.graph.workflows === 1
    && runtime.proof.graph.phases === 1
    && runtime.proof.graph.workflowAgents === 1
    && runtime.proof.graph.workflowOwnerIsNestedAgent
    && runtime.proof.graph.workflowPhaseLinked,
  'workflow, phase, owner, and child graph did not remain distinct and linked')
  invariant(runtime.proof.postRootTerminalCaptured,
    'post-root workflow terminal was not captured')
  invariant(runtime.proof.terminalMonotonicity.terminalState === 'failed'
    && runtime.proof.terminalMonotonicity.staleReportedState === 'progress',
  'stale progress resurrected a terminal child')
  invariant(runtime.proof.repeatedIdenticalToolObservations === 2,
    'identical point tool observations were collapsed')
  invariant(runtime.proof.rawAndPrivateFieldsExcluded,
    'raw workflow handles or outputFile escaped')
  invariant(runtime.proof.terminalRefinement.workflowAgentCount === 1,
    'provider alias rotation split one workflow slot')
  invariant(runtime.proof.terminalRefinement.rawAliasesExcluded,
    'terminal refinement leaked provider aliases')
  invariant(runtime.proof.terminalRefinement.workflowStates.some((item) =>
    item.provenance === 'provider-terminal-failure-refinement'),
  'completed workflow did not retain its explicit failure refinement')
  invariant(runtime.proof.terminalRefinement.childStates.some((item) =>
    item.provenance === 'provider-terminal-failure-refinement'),
  'completed child did not retain its explicit failure refinement')
  invariant(runtime.proof.terminalRefinement.workflowStates.at(-1).state === 'failed',
    'late active workflow update resurrected terminal state')
  invariant(runtime.proof.legacySidecar.exactLifecycleEvents > 0
    && runtime.proof.legacySidecar.degradedLifecycleEvents === 1,
  'sidecar exact/degraded ownership proof failed')
  invariant(runtime.proof.legacySidecar.rawAndPrivateLocatorsExcluded,
    'sidecar proof leaked raw handles or outputFile')
}

export function buildWorkflowLifecycleEvidence(runtime) {
  validateRuntime(runtime)
  const cases = Object.fromEntries(runtime.corpusManifest.document.cases
    .filter((item) => [4, 5, 6, 7].includes(item.id))
    .map((item) => [String(item.id), {
      status: item.status,
      fixtureRefs: item.fixtureRefs,
    }]))
  invariant(Object.keys(cases).length === 4,
    'corpus manifest must expose cases 4, 5, 6, and 7')
  const observed =
    runtime.oracle.reviewedSidecarInventory.observedCorpus.dispositions
  const capture =
    runtime.oracle.reviewedCaptureSurface.totalDispositions
  const productionPaths =
    runtime.oracle.reviewedSidecarInventory.reviewedProductionSchemaOnly.paths
  return {
    evidenceVersion: C15_EVIDENCE_VERSION,
    asOf: '2026-08-03',
    verdict: 'workflow-lifecycle-checkpoint-proven-format-review-blocked',
    predecessor: {
      path: runtime.predecessor.relativePath,
      sha256: runtime.predecessor.sha256,
      evidenceVersion: runtime.predecessor.document.evidenceVersion,
    },
    source: {
      repository: 'mechanician',
      commit: runtime.source.commit,
      cleanTree: runtime.source.cleanTree,
    },
    generation: {
      command: 'node spike/format-r2/workflow-lifecycle-evidence.mjs',
      deterministicFixtures: true,
    },
    verification: {
      requiredCommands: [
        'node --test spike/format-r2/test/workflow-lifecycle-evidence.test.mjs',
        'node --test spike/format-r2/test/*.test.mjs',
        './scripts/check.sh',
      ],
      resultsRecordedIn:
        'docs/mechanician/agent-document-format/format-review-completion-plan-2026-08-03.md',
      crossRepositoryDriftCheck:
        'regenerate twice and byte-compare after corpus-manifest pins are final',
    },
    fixtures: runtime.fixtures,
    sanitizedCorpusManifest: {
      path: runtime.corpusManifest.relativePath,
      sha256: runtime.corpusManifest.sha256,
    },
    reviewedSidecarInventory: runtime.oracle.reviewedSidecarInventory,
    reviewedCaptureSurface: runtime.oracle.reviewedCaptureSurface,
    deltaFromPredecessor: evidenceDeltaFromPredecessor({
      observedSidecarDispositions: observed,
      captureDispositions: capture,
      separatelyReviewedProductionSidecarPaths: productionPaths,
    }, runtime.predecessor.document),
    workflowLifecycle: runtime.proof,
    corpusCases: cases,
    prototypeValidity: {
      'A:vcon+agent_session':
        'fit-gap projection only; workflow identity and lifecycle require declared extensions',
      'B:acr-vac':
        'fit-gap projection only; workflow identity and lifecycle require declared extensions',
      'C:canonical-graph':
        'selected workflow subset with one event authority; the formal format review remains blocked',
    },
    stopGaps: [
      'provider-observed tool cancellation remains separate and is never inferred',
      'tool and child retryOf relationships remain separate and are never inferred from attempt',
      'portable conversation identity, artifacts, disclosure profiles, lineage, amendment, signatures and replay profiles remain open C1 work',
      'C2 physical binding and C3 operational-policy evidence remain open',
      'no convrec, mecha, mechjournal, UTI, menu item or new authority is activated',
    ],
  }
}

export async function runtimeFromRepositories() {
  const externalEvidence = resolveFormatEvidenceRepository()
  const predecessorPath = path.join(
    externalEvidence.evidenceDirectory, C15_PREDECESSOR_FILENAME)
  const corpusManifestPath = path.join(
    externalEvidence.evidenceDirectory, 'corpus-manifest.json')
  const sourceCommit = execFileSync('git', ['rev-parse', 'HEAD'], {
    cwd: repo, encoding: 'utf8', stdio: ['ignore', 'pipe', 'inherit'],
  }).trim()
  const sourceTreeClean = execFileSync('git', ['status', '--porcelain'], {
    cwd: repo, encoding: 'utf8', stdio: ['ignore', 'pipe', 'inherit'],
  }).trim() === ''
  if (!sourceTreeClean) {
    throw new Error('workflow lifecycle evidence requires a clean Mechanician source tree')
  }
  const predecessorBytes = fs.readFileSync(predecessorPath)
  const corpusBytes = fs.readFileSync(corpusManifestPath)
  const fixturePaths = [fileURLToPath(import.meta.url), workflowFixturePath]
  return {
    source: { commit: sourceCommit, cleanTree: sourceTreeClean },
    evidenceDirectory: externalEvidence.evidenceDirectory,
    predecessor: {
      relativePath: path.relative(externalEvidence.repositoryRoot, predecessorPath),
      sha256: sha256Bytes(predecessorBytes),
      document: JSON.parse(predecessorBytes),
    },
    corpusManifest: {
      relativePath: path.relative(externalEvidence.repositoryRoot, corpusManifestPath),
      sha256: sha256Bytes(corpusBytes),
      document: JSON.parse(corpusBytes),
    },
    fixture: {
      path: path.relative(repo, workflowFixturePath),
      sha256: sha256File(workflowFixturePath),
    },
    fixtures: fixturePaths.map((fixture) => ({
      path: path.relative(repo, fixture),
      sha256: sha256File(fixture),
    })),
    oracle: currentWorkflowOracleSnapshot(),
    proof: await collectWorkflowLifecycleProof(),
  }
}

const invokedPath = process.argv[1] == null ? null : path.resolve(process.argv[1])
if (invokedPath === fileURLToPath(import.meta.url)) {
  const runtime = await runtimeFromRepositories()
  const evidence = buildWorkflowLifecycleEvidence(runtime)
  const destination = path.join(runtime.evidenceDirectory, C15_ARTIFACT_FILENAME)
  fs.writeFileSync(destination, JSON.stringify(evidence, null, 2) + '\n')
  process.stdout.write(destination + '\n')
}
