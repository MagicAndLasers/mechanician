// Deterministic successor evidence for bounded format-review checkpoint C1.6.
//
// The executable refuses dirty Mechanician source and writes only the sibling evidence artifact.
// Unit tests exercise the pure contract and builder with injected repository metadata, so this
// non-activated spike can be committed before an exact source object is pinned.
import crypto from 'node:crypto'
import fs from 'node:fs'
import path from 'node:path'
import { execFileSync } from 'node:child_process'
import { fileURLToPath } from 'node:url'

import { evidenceDeltaFromPredecessor } from './evidence-delta.mjs'
import { resolveFormatEvidenceRepository } from './external-evidence-repository.mjs'
import { classifySidecarField } from './canonical-field-contract.mjs'
import {
  PORTABLE_IDENTITY_CONTRACT,
  PORTABLE_IDENTITY_TRANSITION_MATRIX,
  applyIdentityTransition,
  compareIdentityStates,
  createDeterministicTestAllocator,
  makeInitialIdentityState,
  portableBytes,
  sha256,
  stableJSON,
  validateIdentityState,
} from './identity-derivation-contract.mjs'

export const C16_EVIDENCE_VERSION = 8
export const C16_ARTIFACT_FILENAME =
  'r2-identity-derivation-coverage-2026-08-03.json'
export const C16_PREDECESSOR_FILENAME =
  'r2-workflow-lifecycle-coverage-2026-08-03.json'
export const C16_PREDECESSOR_SHA256 =
  '2cd0d219e9bbae0c2fe5e071721b07561a3d1458793afc94f0fe12e5bd1c078e'
export const C16_LOCAL_FORK_PROVENANCE_FIELDS = Object.freeze([
  'forkProvenance', 'forkProvenance.kind',
  'forkProvenance.sourceConversationID', 'forkProvenance.sourceTitleSnapshot',
  'forkProvenance.forkPointEntryID', 'forkProvenance.createdAt',
])

const here = path.dirname(fileURLToPath(import.meta.url))
const repo = path.resolve(here, '..', '..')
const contractPath = path.join(here, 'identity-derivation-contract.mjs')

const sha256Bytes = (bytes) => crypto.createHash('sha256').update(bytes).digest('hex')
const sha256File = (file) => sha256Bytes(fs.readFileSync(file))
const invariant = (condition, message) => {
  if (!condition) throw new Error(`C1.6 evidence invariant failed: ${message}`)
}

function scenario(seed, { signed = false } = {}) {
  const allocator = createDeterministicTestAllocator(seed)
  const source = makeInitialIdentityState({
    allocator,
    signed,
    locator: `/private/${seed}/source.placeholder`,
    content: {
      title: 'Portable identity proof',
      events: [
        { id: 'event-1', actor: 'user', text: 'Retained prompt' },
        { id: 'event-2', actor: 'assistant', text: 'Retained answer' },
      ],
    },
  })
  return { allocator, source }
}

function transitionProof(before, after) {
  return {
    comparison: compareIdentityStates(before, after),
    before: {
      lineageId: before.portable.lineageId,
      versionId: before.portable.versionId,
      exactByteDigest: before.validation.exactByteDigest,
      semanticDigest: before.validation.semanticDigest,
      fileInstanceId: before.local.fileInstanceId,
      registrationId: before.local.registrationId,
      overlayId: before.local.overlay?.overlayId ?? null,
    },
    after: {
      lineageId: after.portable.lineageId,
      versionId: after.portable.versionId,
      exactByteDigest: after.validation.exactByteDigest,
      semanticDigest: after.validation.semanticDigest,
      fileInstanceId: after.local.fileInstanceId,
      registrationId: after.local.registrationId,
      overlayId: after.local.overlay?.overlayId ?? null,
      writable: after.writable,
      relationshipTypes: after.portable.relationships.map((item) => item.type),
      signatureStatus: after.validation.signature.status,
    },
  }
}

function caughtDiagnostic(action) {
  try {
    action()
  } catch (error) {
    return error instanceof Error ? error.message : String(error)
  }
  throw new Error('C1.6 evidence invariant failed: expected fail-closed diagnostic')
}

export function identityDerivationProof() {
  const meaningful = scenario('meaningful-save')
  const meaningfulAfter = applyIdentityTransition(
    meaningful.source, 'meaningful-save', {
      allocator: meaningful.allocator,
      content: {
        ...meaningful.source.portable.content,
        events: [...meaningful.source.portable.content.events,
          { id: 'event-3', actor: 'assistant', text: 'Meaningful new fact' }],
      },
    })

  const noOp = scenario('no-op-save')
  const noOpAfter = applyIdentityTransition(noOp.source, 'no-op-save')

  const imported = scenario('import-as-new-conversation')
  const importedAfter = applyIdentityTransition(
    imported.source, 'import-as-new-conversation', {
      allocator: imported.allocator,
      locator: '/private/import-as-new-conversation/imported.placeholder',
    })

  const moved = scenario('move-or-rename')
  const movedAfter = applyIdentityTransition(moved.source, 'move-or-rename', {
    locator: '/private/move-or-rename/renamed.placeholder',
  })

  const duplicate = scenario('finder-duplicate-before-fork')
  const duplicateAfter = applyIdentityTransition(
    duplicate.source, 'finder-duplicate-before-fork', {
      allocator: duplicate.allocator,
      locator: '/private/finder-duplicate-before-fork/copy.placeholder',
    })
  const forkAfter = applyIdentityTransition(duplicateAfter, 'explicit-fork', {
    allocator: duplicate.allocator,
  })

  const amendment = scenario('amendment')
  const amendmentAfter = applyIdentityTransition(amendment.source, 'amendment', {
    allocator: amendment.allocator,
    content: {
      ...amendment.source.portable.content,
      events: amendment.source.portable.content.events.map((event) =>
        event.id === 'event-2' ? { ...event, text: 'Corrected retained answer' } : event),
    },
  })

  const redacted = scenario('redacted-derived-snapshot')
  const redactedAfter = applyIdentityTransition(
    redacted.source, 'redacted-derived-snapshot', {
      allocator: redacted.allocator,
      locator: '/private/redacted-derived-snapshot/redacted.placeholder',
      content: {
        ...redacted.source.portable.content,
        events: redacted.source.portable.content.events.filter((event) => event.id !== 'event-2'),
      },
      omittedCategories: ['assistant-dialog'],
    })

  const signed = scenario('signed-source-adaptation', { signed: true })
  const signedSourceBytes = portableBytes(signed.source)
  const adaptedAfter = applyIdentityTransition(
    signed.source, 'signed-source-adaptation', {
      allocator: signed.allocator,
      locator: '/private/signed-source-adaptation/adapted.placeholder',
    })
  const preservedSignedSource = adaptedAfter.portable.preservedSignedSources[0]

  const invalidOverlay = structuredClone(duplicateAfter)
  invalidOverlay.local.overlay = structuredClone(duplicate.source.local.overlay)
  invalidOverlay.local.overlay.registrationId = duplicateAfter.local.registrationId
  invalidOverlay.writable = true
  const tamperedDigest = structuredClone(noOp.source)
  tamperedDigest.portable.content.title = 'Tampered without a new version'
  const inheritedSignature = structuredClone(adaptedAfter)
  inheritedSignature.portable.signatureEnvelope = structuredClone(
    signed.source.portable.signatureEnvelope)
  inheritedSignature.validation.exactByteDigest = sha256(portableBytes(inheritedSignature))
  inheritedSignature.validation.signature = {
    status: 'verified-test-fixture',
    boundExactByteDigest: inheritedSignature.validation.exactByteDigest,
  }

  const scenarios = {
    'meaningful-save': transitionProof(meaningful.source, meaningfulAfter),
    'no-op-save': transitionProof(noOp.source, noOpAfter),
    'import-as-new-conversation': transitionProof(imported.source, importedAfter),
    'move-or-rename': {
      ...transitionProof(moved.source, movedAfter),
      locatorChanged: moved.source.local.locator !== movedAfter.local.locator,
    },
    'finder-duplicate-before-fork': {
      ...transitionProof(duplicate.source, duplicateAfter),
      duplicateOverlayAttached: duplicateAfter.local.overlay != null,
    },
    'explicit-fork': transitionProof(duplicateAfter, forkAfter),
    amendment: transitionProof(amendment.source, amendmentAfter),
    'redacted-derived-snapshot': transitionProof(redacted.source, redactedAfter),
    'signed-source-adaptation': {
      ...transitionProof(signed.source, adaptedAfter),
      sourceBytesPreservedExactly:
        preservedSignedSource?.bytesBase64 === signedSourceBytes.toString('base64'),
      preservedSourceDigestMatches:
        preservedSignedSource?.exactByteDigest === sha256(signedSourceBytes),
      derivedSignatureEnvelopeAbsent: adaptedAfter.portable.signatureEnvelope == null,
    },
  }
  const resultingStates = [
    meaningfulAfter, noOpAfter, importedAfter, movedAfter, duplicateAfter, forkAfter,
    amendmentAfter, redactedAfter, adaptedAfter,
  ]

  const expectedScenarioIds = PORTABLE_IDENTITY_TRANSITION_MATRIX.map((item) => item.id)
  invariant(stableJSON(Object.keys(scenarios)) === stableJSON(expectedScenarioIds),
    'transition proof does not exactly cover the machine-readable matrix')
  invariant(!scenarios['meaningful-save'].comparison.sameRecordVersion
    && scenarios['meaningful-save'].comparison.sameLineage,
  'meaningful save did not mint one version in the same lineage')
  invariant(stableJSON(noOp.source) === stableJSON(noOpAfter),
    'no-op save changed state or minted a version')
  invariant(scenarios['import-as-new-conversation'].comparison.semanticEquivalent
    && !scenarios['import-as-new-conversation'].comparison.exactByteEqual,
  'lossless import conflated semantic equivalence with byte equality')
  invariant(scenarios['move-or-rename'].locatorChanged
    && scenarios['move-or-rename'].comparison.exactByteEqual
    && scenarios['move-or-rename'].comparison.sameFileInstance,
  'move/rename changed identity or portable bytes')
  invariant(!scenarios['finder-duplicate-before-fork'].comparison.sameFileInstance
    && scenarios['finder-duplicate-before-fork'].comparison.sameLineage
    && !scenarios['finder-duplicate-before-fork'].duplicateOverlayAttached,
  'Finder duplicate reused the source file instance or overlay')
  invariant(!scenarios['explicit-fork'].comparison.sameLineage
    && scenarios['explicit-fork'].comparison.semanticEquivalent
    && scenarios['explicit-fork'].after.relationshipTypes.includes('forkedFrom'),
  'explicit fork did not mint a declared writable lineage')
  invariant(scenarios.amendment.after.relationshipTypes.includes('previousVersion')
    && scenarios.amendment.after.relationshipTypes.includes('amends')
    && !scenarios.amendment.comparison.semanticEquivalent,
  'amendment did not distinguish version order, amendment, and semantic change')
  invariant(scenarios['redacted-derived-snapshot'].after.relationshipTypes.includes('derivedFrom')
    && scenarios['redacted-derived-snapshot'].after.relationshipTypes.includes('amends')
    && !scenarios['redacted-derived-snapshot'].comparison.semanticEquivalent,
  'redaction did not declare derivation, amendment, and semantic change')
  invariant(scenarios['signed-source-adaptation'].sourceBytesPreservedExactly
    && scenarios['signed-source-adaptation'].preservedSourceDigestMatches
    && scenarios['signed-source-adaptation'].derivedSignatureEnvelopeAbsent
    && scenarios['signed-source-adaptation'].after.signatureStatus === 'unsigned-derived',
  'adaptation inherited a signature or failed to preserve signed source bytes')

  return {
    contractVersion: PORTABLE_IDENTITY_CONTRACT.status,
    matrixScenarioIds: expectedScenarioIds,
    scenarios,
    failClosedDiagnostics: {
      unknownTransition: caughtDiagnostic(() =>
        applyIdentityTransition(noOp.source, 'infer-from-path', {})),
      pathOrCallerIdentityInjection: caughtDiagnostic(() =>
        applyIdentityTransition(imported.source, 'import-as-new-conversation', {
          allocator: imported.allocator,
          locator: '/private/injected.placeholder',
          lineageId: imported.source.local.locator,
        })),
      tamperedBytes: caughtDiagnostic(() => validateIdentityState(tamperedDigest)),
      overlayAttachedByLineageAlone:
        caughtDiagnostic(() => validateIdentityState(invalidOverlay)),
      inheritedSignature: caughtDiagnostic(() => validateIdentityState(inheritedSignature)),
    },
    portablePrivacy: {
      localLocatorsExcluded: resultingStates.every((state) => {
        const bytes = portableBytes(state).toString('utf8')
        return !bytes.includes('/private/') && !bytes.includes(state.local.locator)
      }),
      localRegistrationIdentitiesExcluded: resultingStates.every((state) => {
        const bytes = portableBytes(state).toString('utf8')
        return ![
          state.local.fileInstanceId,
          state.local.registrationId,
          state.local.overlay?.overlayId,
          state.local.legacyConversationId,
        ].filter(Boolean).some((identity) => bytes.includes(identity))
      }),
      legacyConversationIdentityIsPrivate:
        PORTABLE_IDENTITY_CONTRACT.domains.legacyConversationId.scope
          === 'private-legacy-application',
    },
    rootCIdentityEnvelope: {
      unexplainedDifferences: 0,
      inferredPortableIdentities: 0,
      inheritedSignatures: 0,
      overlaysAttachedByLineageAlone: 0,
      ambiguousWritableDuplicates: 0,
    },
  }
}

function validateRuntime(runtime) {
  invariant(runtime?.source?.cleanTree === true, 'source tree must be clean')
  invariant(/^[0-9a-f]{40}$/.test(runtime?.source?.commit ?? ''),
    'source commit must be one exact Git object')
  invariant(runtime?.predecessor?.sha256 === C16_PREDECESSOR_SHA256,
    'predecessor digest changed')
  invariant(runtime?.predecessor?.document?.evidenceVersion === 7,
    'predecessor must be evidence version 7')
  invariant(runtime?.predecessor?.relativePath?.endsWith(C16_PREDECESSOR_FILENAME),
    'predecessor path changed')
  invariant(/^[0-9a-f]{64}$/.test(runtime?.contract?.sourceSha256 ?? ''),
    'identity contract source digest is missing')
  invariant(runtime.contract.semanticSha256 === sha256(Buffer.from(stableJSON({
    identityContract: PORTABLE_IDENTITY_CONTRACT,
    transitionMatrix: PORTABLE_IDENTITY_TRANSITION_MATRIX,
  }))), 'identity contract semantic digest changed')
  invariant(/^[0-9a-f]{64}$/.test(runtime?.corpusManifest?.sha256 ?? ''),
    'corpus manifest must have an exact digest')
  invariant(runtime?.proof?.rootCIdentityEnvelope?.unexplainedDifferences === 0,
    'root-C identity envelope has unexplained differences')
  invariant(runtime.proof.rootCIdentityEnvelope.inferredPortableIdentities === 0,
    'portable identity was inferred')
  invariant(runtime.proof.rootCIdentityEnvelope.inheritedSignatures === 0,
    'derived bytes inherited a signature')
  invariant(runtime.proof.rootCIdentityEnvelope.overlaysAttachedByLineageAlone === 0,
    'an overlay was attached by portable lineage alone')
  invariant(runtime.proof.rootCIdentityEnvelope.ambiguousWritableDuplicates === 0,
    'duplicate file instances remained ambiguously writable')
  invariant(runtime.proof.portablePrivacy.localLocatorsExcluded,
    'private locators entered portable bytes')
  invariant(runtime.proof.portablePrivacy.localRegistrationIdentitiesExcluded,
    'private registration identities entered portable bytes')
  invariant(runtime.proof.portablePrivacy.legacyConversationIdentityIsPrivate,
    'legacy Conversation.id was promoted to portable identity')
  invariant(Object.keys(runtime.proof.failClosedDiagnostics).length === 5,
    'fail-closed misuse diagnostics are incomplete')
  invariant(C16_LOCAL_FORK_PROVENANCE_FIELDS.every((field) =>
    classifySidecarField(field)?.classification === 'private-local'),
  'current-JSON fork provenance was not kept separate from portable lineage')
}

export function buildIdentityDerivationEvidence(runtime) {
  validateRuntime(runtime)
  const cases = Object.fromEntries(runtime.corpusManifest.document.cases
    .filter((item) => [18, 20, 24].includes(item.id))
    .map((item) => [String(item.id), {
      status: item.status,
      fixtureRefs: item.fixtureRefs,
      expectedDiagnosticClasses: item.expectedDiagnosticClasses,
    }]))
  invariant(Object.keys(cases).length === 3,
    'corpus manifest must expose cases 18, 20, and 24')
  const priorSidecar = runtime.predecessor.document.reviewedSidecarInventory
  const priorCapture = runtime.predecessor.document.reviewedCaptureSurface
  invariant(priorSidecar?.observedCorpus?.dispositions != null
    && priorSidecar?.reviewedProductionSchemaOnly?.paths != null
    && priorCapture?.totalDispositions != null,
  'predecessor inventories are incomplete')
  const currentSidecar = structuredClone(priorSidecar)
  currentSidecar.reviewedProductionSchemaOnly.paths +=
    C16_LOCAL_FORK_PROVENANCE_FIELDS.length
  currentSidecar.reviewedProductionSchemaOnly.dispositions['private-local'] =
    (currentSidecar.reviewedProductionSchemaOnly.dispositions['private-local'] ?? 0)
      + C16_LOCAL_FORK_PROVENANCE_FIELDS.length
  return {
    evidenceVersion: C16_EVIDENCE_VERSION,
    asOf: '2026-08-03',
    verdict: 'portable-identity-derivation-contract-proven-format-review-blocked',
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
      command: 'node spike/format-r2/identity-derivation-evidence.mjs',
      deterministicFixtures: true,
    },
    verification: {
      requiredCommands: [
        'node --test spike/format-r2/test/identity-derivation-evidence.test.mjs',
        'node --test spike/format-r2/test/*.test.mjs',
        './scripts/check.sh',
      ],
      crossRepositoryDriftCheck:
        'regenerate twice and byte-compare after the final clean source commit is fixed',
    },
    fixtures: runtime.fixtures,
    identityContract: {
      path: runtime.contract.relativePath,
      sourceSha256: runtime.contract.sourceSha256,
      semanticSha256: runtime.contract.semanticSha256,
      document: PORTABLE_IDENTITY_CONTRACT,
      transitionMatrix: PORTABLE_IDENTITY_TRANSITION_MATRIX,
    },
    sanitizedCorpusManifest: {
      path: runtime.corpusManifest.relativePath,
      sha256: runtime.corpusManifest.sha256,
    },
    reviewedSidecarInventory: currentSidecar,
    reviewedCaptureSurface: priorCapture,
    deltaFromPredecessor: evidenceDeltaFromPredecessor({
      observedSidecarDispositions: currentSidecar.observedCorpus.dispositions,
      captureDispositions: priorCapture.totalDispositions,
      separatelyReviewedProductionSidecarPaths:
        currentSidecar.reviewedProductionSchemaOnly.paths,
    }, runtime.predecessor.document),
    currentJSONForkProvenance: {
      status: 'private-local-legacy-identity-not-portable-lineage',
      reviewedFields: C16_LOCAL_FORK_PROVENANCE_FIELDS.map((path) => ({
        path, classification: classifySidecarField(path).classification,
      })),
      futureAdapterRequirement:
        'resolve explicit source lineage/version and fork point; never infer from local UUID, title, path, timestamp, or provider session',
    },
    identityDerivation: runtime.proof,
    corpusCases: cases,
    prototypeValidity: {
      'C:canonical-graph':
        'non-activated identity envelope and transition contract with zero unexplained differences; public schema remains unfrozen',
      signatures:
        'identity semantics only; cryptographic validation and exact-byte binding remain C2 work',
    },
    stopGaps: [
      'current-JSON fork provenance remains private local input until a future adapter resolves explicit portable lineage/version links',
      'cryptographic signature validation and exact-byte binding remain C2 work',
      'disclosure-profile pseudonymization and bundle-local lineage remain open C1 work',
      'provider-observed tool cancellation and retryOf remain separate and are never inferred',
      'C2 physical binding and C3 operational-policy evidence remain open',
      'no convrec, mecha, mechjournal, UTI, menu item, registration store or new authority is activated',
    ],
  }
}

export function runtimeFromRepositories() {
  const externalEvidence = resolveFormatEvidenceRepository()
  const predecessorPath = path.join(
    externalEvidence.evidenceDirectory, C16_PREDECESSOR_FILENAME)
  const corpusManifestPath = path.join(
    externalEvidence.evidenceDirectory, 'corpus-manifest.json')
  const sourceCommit = execFileSync('git', ['rev-parse', 'HEAD'], {
    cwd: repo, encoding: 'utf8', stdio: ['ignore', 'pipe', 'inherit'],
  }).trim()
  const sourceTreeClean = execFileSync('git', ['status', '--porcelain'], {
    cwd: repo, encoding: 'utf8', stdio: ['ignore', 'pipe', 'inherit'],
  }).trim() === ''
  if (!sourceTreeClean) {
    throw new Error('identity derivation evidence requires a clean Mechanician source tree')
  }
  const predecessorBytes = fs.readFileSync(predecessorPath)
  const corpusBytes = fs.readFileSync(corpusManifestPath)
  const semanticContractBytes = Buffer.from(stableJSON({
    identityContract: PORTABLE_IDENTITY_CONTRACT,
    transitionMatrix: PORTABLE_IDENTITY_TRANSITION_MATRIX,
  }))
  const fixturePaths = [fileURLToPath(import.meta.url), contractPath]
  return {
    source: { commit: sourceCommit, cleanTree: sourceTreeClean },
    evidenceDirectory: externalEvidence.evidenceDirectory,
    predecessor: {
      relativePath: path.relative(externalEvidence.repositoryRoot, predecessorPath),
      sha256: sha256Bytes(predecessorBytes),
      document: JSON.parse(predecessorBytes),
    },
    contract: {
      relativePath: path.relative(repo, contractPath),
      sourceSha256: sha256File(contractPath),
      semanticSha256: sha256Bytes(semanticContractBytes),
    },
    corpusManifest: {
      relativePath: path.relative(externalEvidence.repositoryRoot, corpusManifestPath),
      sha256: sha256Bytes(corpusBytes),
      document: JSON.parse(corpusBytes),
    },
    fixtures: fixturePaths.map((fixture) => ({
      path: path.relative(repo, fixture),
      sha256: sha256File(fixture),
    })),
    proof: identityDerivationProof(),
  }
}

const invokedPath = process.argv[1] == null ? null : path.resolve(process.argv[1])
if (invokedPath === fileURLToPath(import.meta.url)) {
  const runtime = runtimeFromRepositories()
  const evidence = buildIdentityDerivationEvidence(runtime)
  const destination = path.join(runtime.evidenceDirectory, C16_ARTIFACT_FILENAME)
  fs.writeFileSync(destination, JSON.stringify(evidence, null, 2) + '\n')
  process.stdout.write(destination + '\n')
}
