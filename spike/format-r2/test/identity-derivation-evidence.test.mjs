import assert from 'node:assert/strict'
import test from 'node:test'

import {
  IDENTITY_CONTRACT_VERSION,
  PORTABLE_IDENTITY_CONTRACT,
  PORTABLE_IDENTITY_TRANSITION_MATRIX,
  SEMANTIC_DIGEST_PROFILE,
  applyIdentityTransition,
  compareIdentityStates,
  createDeterministicTestAllocator,
  makeInitialIdentityState,
  portableBytes,
  semanticDigest,
  sha256,
  stableJSON,
  validateIdentityState,
} from '../identity-derivation-contract.mjs'
import {
  C16_EVIDENCE_VERSION,
  C16_LOCAL_FORK_PROVENANCE_FIELDS,
  C16_PREDECESSOR_FILENAME,
  C16_PREDECESSOR_SHA256,
  buildIdentityDerivationEvidence,
  identityDerivationProof,
} from '../identity-derivation-evidence.mjs'

function initial(seed, { signed = false } = {}) {
  const allocator = createDeterministicTestAllocator(seed)
  return {
    allocator,
    state: makeInitialIdentityState({
      allocator,
      signed,
      locator: `/private/${seed}/source.placeholder`,
    }),
  }
}

function predecessor() {
  return {
    evidenceVersion: 7,
    reviewedSidecarInventory: {
      observedCorpus: {
        paths: 114,
        dispositions: {
          canonical: 33, 'intentionally-omitted': 5,
          'not-yet-captured': 73, 'private-local': 3,
        },
        unclassified: 0,
      },
      reviewedProductionSchemaOnly: {
        paths: 59,
        dispositions: {
          canonical: 41, 'derived-projection': 3,
          'intentionally-omitted': 15,
        },
        unclassified: 0,
      },
    },
    reviewedCaptureSurface: {
      reviewedPaths: 236,
      totalDispositions: {
        canonical: 168, 'derived-projection': 2,
        'intentionally-omitted': 60, 'private-local': 6,
      },
      unclassified: 0,
    },
  }
}

function runtime() {
  return {
    source: { commit: 'a'.repeat(40), cleanTree: true },
    predecessor: {
      relativePath:
        `docs/mechanician/agent-document-format/${C16_PREDECESSOR_FILENAME}`,
      sha256: C16_PREDECESSOR_SHA256,
      document: predecessor(),
    },
    contract: {
      relativePath: 'spike/format-r2/identity-derivation-contract.mjs',
      sourceSha256: 'b'.repeat(64),
      semanticSha256: sha256(Buffer.from(stableJSON({
        identityContract: PORTABLE_IDENTITY_CONTRACT,
        transitionMatrix: PORTABLE_IDENTITY_TRANSITION_MATRIX,
      }))),
    },
    corpusManifest: {
      relativePath: 'docs/mechanician/agent-document-format/corpus-manifest.json',
      sha256: 'c'.repeat(64),
      document: {
        cases: [18, 20, 24].map((id) => ({
          id,
          status: id === 18 ? 'partial-seed-available' : 'missing',
          fixtureRefs: id === 18 ? ['agentd-steering-busy'] : [],
          expectedDiagnosticClasses: [`case-${id}-diagnostic`],
        })),
      },
    },
    fixtures: [{
      path: 'spike/format-r2/identity-derivation-contract.mjs',
      sha256: 'b'.repeat(64),
    }],
    proof: identityDerivationProof(),
  }
}

test('identity contract keeps portable, byte, semantic, and private domains distinct', () => {
  assert.equal(PORTABLE_IDENTITY_CONTRACT.status, 'non-activated-format-review-spike')
  assert.equal(PORTABLE_IDENTITY_CONTRACT.domains.conversationLineage.scope, 'portable')
  assert.equal(PORTABLE_IDENTITY_CONTRACT.domains.recordVersion.mutability, 'immutable')
  assert.equal(PORTABLE_IDENTITY_CONTRACT.domains.fileInstance.scope, 'private-local')
  assert.equal(PORTABLE_IDENTITY_CONTRACT.domains.runtimeOverlay.scope, 'private-local')
  assert.equal(PORTABLE_IDENTITY_CONTRACT.domains.legacyConversationId.scope,
    'private-legacy-application')
  assert.ok(PORTABLE_IDENTITY_CONTRACT.domains.conversationLineage.neverMintedFrom
    .includes('providerSessionId'))
  assert.ok(PORTABLE_IDENTITY_CONTRACT.domains.conversationLineage.neverMintedFrom
    .includes('path'))
  assert.deepEqual(Object.keys(PORTABLE_IDENTITY_CONTRACT.relationshipTypes), [
    'previousVersion', 'derivedFrom', 'amends', 'forkedFrom',
  ])
  assert.equal(PORTABLE_IDENTITY_CONTRACT.signatureRule.inheritedByNewVersion, false)
})

test('meaningful and no-op saves have different immutable-version behavior', () => {
  const fixture = initial('save-proof')
  const noOp = applyIdentityTransition(fixture.state, 'no-op-save')
  assert.deepEqual(noOp, fixture.state)

  const changed = applyIdentityTransition(fixture.state, 'meaningful-save', {
    allocator: fixture.allocator,
    content: { ...fixture.state.portable.content, title: 'Meaningfully changed' },
  })
  const comparison = compareIdentityStates(fixture.state, changed)
  assert.equal(comparison.sameLineage, true)
  assert.equal(comparison.sameRecordVersion, false)
  assert.equal(comparison.exactByteEqual, false)
  assert.equal(comparison.semanticEquivalent, false)
  assert.deepEqual(comparison.addedRelationshipTypes, ['previousVersion'])
  assert.equal(changed.portable.relationships[0].target.versionId,
    fixture.state.portable.versionId)

  assert.throws(() => applyIdentityTransition(fixture.state, 'meaningful-save', {
    allocator: fixture.allocator,
    content: structuredClone(fixture.state.portable.content),
  }), /cannot publish unchanged content/)
})

test('lossless import and move separate semantic, byte, and file identity', () => {
  const fixture = initial('import-move-proof')
  const imported = applyIdentityTransition(fixture.state, 'import-as-new-conversation', {
    allocator: fixture.allocator,
    locator: '/private/import-move-proof/imported.placeholder',
  })
  const importedComparison = compareIdentityStates(fixture.state, imported)
  assert.equal(importedComparison.sameLineage, false)
  assert.equal(importedComparison.sameRecordVersion, false)
  assert.equal(importedComparison.exactByteEqual, false)
  assert.equal(importedComparison.semanticEquivalent, true)
  assert.equal(importedComparison.sameFileInstance, false)
  assert.deepEqual(importedComparison.addedRelationshipTypes, ['derivedFrom'])

  const moved = applyIdentityTransition(fixture.state, 'move-or-rename', {
    locator: '/private/import-move-proof/renamed.placeholder',
  })
  const movedComparison = compareIdentityStates(fixture.state, moved)
  assert.equal(movedComparison.sameLineage, true)
  assert.equal(movedComparison.sameRecordVersion, true)
  assert.equal(movedComparison.exactByteEqual, true)
  assert.equal(movedComparison.semanticEquivalent, true)
  assert.equal(movedComparison.sameFileInstance, true)
  assert.equal(movedComparison.sameRegistration, true)
  assert.equal(movedComparison.sameOverlay, true)
  assert.notEqual(moved.local.locator, fixture.state.local.locator)
})

test('Finder duplicate has a new private instance and cannot write until explicit fork', () => {
  const fixture = initial('duplicate-fork-proof')
  const duplicate = applyIdentityTransition(
    fixture.state, 'finder-duplicate-before-fork', {
      allocator: fixture.allocator,
      locator: '/private/duplicate-fork-proof/copy.placeholder',
    })
  const duplicateComparison = compareIdentityStates(fixture.state, duplicate)
  assert.equal(duplicateComparison.sameLineage, true)
  assert.equal(duplicateComparison.sameRecordVersion, true)
  assert.equal(duplicateComparison.exactByteEqual, true)
  assert.equal(duplicateComparison.sameFileInstance, false)
  assert.equal(duplicateComparison.sameRegistration, false)
  assert.equal(duplicate.local.overlay, null)
  assert.equal(duplicate.writable, false)

  const fork = applyIdentityTransition(duplicate, 'explicit-fork', {
    allocator: fixture.allocator,
  })
  const forkComparison = compareIdentityStates(duplicate, fork)
  assert.equal(forkComparison.sameLineage, false)
  assert.equal(forkComparison.sameRecordVersion, false)
  assert.equal(forkComparison.exactByteEqual, false)
  assert.equal(forkComparison.semanticEquivalent, true)
  assert.equal(forkComparison.sameFileInstance, true)
  assert.equal(forkComparison.sameRegistration, true)
  assert.deepEqual(forkComparison.addedRelationshipTypes, ['forkedFrom'])
  assert.equal(fork.writable, true)
  assert.equal(fork.local.overlay.fileInstanceId, duplicate.local.fileInstanceId)
})

test('amendment and redaction declare typed links and semantic change', () => {
  const amendmentFixture = initial('amendment-proof')
  const amended = applyIdentityTransition(amendmentFixture.state, 'amendment', {
    allocator: amendmentFixture.allocator,
    content: { ...amendmentFixture.state.portable.content, title: 'Corrected title' },
  })
  const amendedComparison = compareIdentityStates(amendmentFixture.state, amended)
  assert.equal(amendedComparison.sameLineage, true)
  assert.equal(amendedComparison.semanticEquivalent, false)
  assert.deepEqual(amendedComparison.addedRelationshipTypes, ['previousVersion', 'amends'])

  const redactionFixture = initial('redaction-proof')
  const redacted = applyIdentityTransition(
    redactionFixture.state, 'redacted-derived-snapshot', {
      allocator: redactionFixture.allocator,
      locator: '/private/redaction-proof/redacted.placeholder',
      content: { title: redactionFixture.state.portable.content.title, events: [] },
      omittedCategories: ['dialog'],
    })
  const redactedComparison = compareIdentityStates(redactionFixture.state, redacted)
  assert.equal(redactedComparison.sameLineage, false)
  assert.equal(redactedComparison.semanticEquivalent, false)
  assert.deepEqual(redactedComparison.addedRelationshipTypes, ['derivedFrom', 'amends'])
  assert.deepEqual(redacted.portable.disclosure.omittedCategories, ['dialog'])
})

test('signed adaptation preserves source bytes and never inherits authenticity', () => {
  const fixture = initial('signature-proof', { signed: true })
  const sourceBytes = portableBytes(fixture.state)
  const adapted = applyIdentityTransition(
    fixture.state, 'signed-source-adaptation', {
      allocator: fixture.allocator,
      locator: '/private/signature-proof/adapted.placeholder',
    })
  assert.equal(adapted.validation.signature.status, 'unsigned-derived')
  assert.equal(adapted.validation.signature.boundExactByteDigest, null)
  assert.equal(adapted.portable.signatureEnvelope, null)
  assert.equal(adapted.validation.semanticDigest, fixture.state.validation.semanticDigest)
  assert.notEqual(adapted.validation.exactByteDigest, fixture.state.validation.exactByteDigest)
  assert.equal(adapted.portable.preservedSignedSources.length, 1)
  const preserved = adapted.portable.preservedSignedSources[0]
  assert.equal(preserved.bytesBase64, sourceBytes.toString('base64'))
  assert.equal(preserved.exactByteDigest, sha256(sourceBytes))
  assert.equal(preserved.observedVerification.boundExactByteDigest,
    fixture.state.validation.exactByteDigest)

  const inherited = structuredClone(adapted)
  inherited.portable.signatureEnvelope = structuredClone(fixture.state.portable.signatureEnvelope)
  inherited.validation.exactByteDigest = sha256(portableBytes(inherited))
  inherited.validation.signature = {
    status: 'verified-test-fixture',
    boundExactByteDigest: inherited.validation.exactByteDigest,
  }
  assert.throws(() => validateIdentityState(inherited),
    /signature envelope was inherited from a different record version/)
})

test('state validation fails closed on tampering, identity injection, and overlay reuse', () => {
  const fixture = initial('fail-closed-proof')
  const tampered = structuredClone(fixture.state)
  tampered.portable.content.title = 'Changed behind the validator'
  assert.throws(() => validateIdentityState(tampered), /exact-byte digest/)

  assert.throws(() => applyIdentityTransition(fixture.state, 'infer-from-path'),
    /unknown transition/)
  assert.throws(() => applyIdentityTransition(
    fixture.state, 'import-as-new-conversation', {
      allocator: fixture.allocator,
      locator: '/private/fail-closed-proof/imported.placeholder',
      lineageId: fixture.state.local.locator,
    }), /unknown keys: lineageId/)

  const duplicate = applyIdentityTransition(
    fixture.state, 'finder-duplicate-before-fork', {
      allocator: fixture.allocator,
      locator: '/private/fail-closed-proof/copy.placeholder',
    })
  const reusedOverlay = structuredClone(duplicate)
  reusedOverlay.local.overlay = structuredClone(fixture.state.local.overlay)
  reusedOverlay.local.overlay.registrationId = duplicate.local.registrationId
  reusedOverlay.writable = true
  assert.throws(() => validateIdentityState(reusedOverlay),
    /overlay is attached by lineage rather than file instance/)

  const leakedPrivateIdentity = structuredClone(fixture.state)
  leakedPrivateIdentity.portable.content.privateLocator = fixture.state.local.locator
  leakedPrivateIdentity.validation.exactByteDigest = sha256(portableBytes(leakedPrivateIdentity))
  leakedPrivateIdentity.validation.semanticDigest = semanticDigest(leakedPrivateIdentity)
  assert.throws(() => validateIdentityState(leakedPrivateIdentity),
    /private local identity leaked into portable bytes/)
})

test('v8 proof deterministically covers every transition-matrix row', () => {
  const first = identityDerivationProof()
  const second = identityDerivationProof()
  assert.deepEqual(first, second)
  assert.deepEqual(first.matrixScenarioIds,
    PORTABLE_IDENTITY_TRANSITION_MATRIX.map((item) => item.id))
  assert.equal(first.scenarios['no-op-save'].comparison.sameRecordVersion, true)
  assert.equal(first.scenarios['import-as-new-conversation'].comparison.semanticEquivalent, true)
  assert.equal(first.scenarios['explicit-fork'].after.relationshipTypes[0], 'forkedFrom')
  assert.equal(first.scenarios['signed-source-adaptation'].derivedSignatureEnvelopeAbsent, true)
  assert.equal(first.portablePrivacy.localLocatorsExcluded, true)
  assert.equal(first.portablePrivacy.localRegistrationIdentitiesExcluded, true)
  assert.deepEqual(first.rootCIdentityEnvelope, {
    unexplainedDifferences: 0,
    inferredPortableIdentities: 0,
    inheritedSignatures: 0,
    overlaysAttachedByLineageAlone: 0,
    ambiguousWritableDuplicates: 0,
  })
})

test('v8 successor builder is deterministic and preserves the exact v7 predecessor', () => {
  const first = buildIdentityDerivationEvidence(runtime())
  const second = buildIdentityDerivationEvidence(structuredClone(runtime()))
  assert.deepEqual(first, second)
  assert.equal(first.evidenceVersion, C16_EVIDENCE_VERSION)
  assert.equal(first.predecessor.sha256, C16_PREDECESSOR_SHA256)
  assert.equal(first.predecessor.evidenceVersion, 7)
  assert.deepEqual(Object.keys(first.corpusCases), ['18', '20', '24'])
  assert.equal(first.identityDerivation.rootCIdentityEnvelope.unexplainedDifferences, 0)
  assert.equal(first.deltaFromPredecessor.separatelyReviewedProductionSidecarPaths, 6)
  assert.equal(first.reviewedSidecarInventory.reviewedProductionSchemaOnly.paths, 65)
  assert.equal(
    first.reviewedSidecarInventory.reviewedProductionSchemaOnly
      .dispositions['private-local'],
    6)
  assert.deepEqual(
    first.currentJSONForkProvenance.reviewedFields.map((item) => item.path),
    C16_LOCAL_FORK_PROVENANCE_FIELDS)
  assert.ok(first.currentJSONForkProvenance.reviewedFields.every(
    (item) => item.classification === 'private-local'))
  assert.ok(Object.values(first.deltaFromPredecessor.observedSidecarDispositions)
    .every((value) => value === 0))
  assert.ok(Object.values(first.deltaFromPredecessor.captureDispositions)
    .every((value) => value === 0))
  assert.match(first.prototypeValidity.signatures, /C2/)
  assert.ok(first.stopGaps.some((gap) => gap.includes('no convrec')))
})

test('v8 builder refuses dirty source, drift, incomplete cases, and false proof claims', () => {
  for (const mutate of [
    (value) => { value.source.cleanTree = false },
    (value) => { value.source.commit = 'not-a-commit' },
    (value) => { value.predecessor.sha256 = '0'.repeat(64) },
    (value) => { value.predecessor.document.evidenceVersion = 6 },
    (value) => { value.contract.semanticSha256 = '0'.repeat(64) },
    (value) => { value.corpusManifest.document.cases.pop() },
    (value) => { value.proof.rootCIdentityEnvelope.inferredPortableIdentities = 1 },
    (value) => { value.proof.rootCIdentityEnvelope.inheritedSignatures = 1 },
    (value) => { value.proof.portablePrivacy.localLocatorsExcluded = false },
    (value) => { value.proof.portablePrivacy.localRegistrationIdentitiesExcluded = false },
  ]) {
    const changed = runtime()
    mutate(changed)
    assert.throws(() => buildIdentityDerivationEvidence(changed),
      /C1\.6 evidence invariant failed/)
  }
})

test('test identities and semantic profile are stable but explicitly non-production', () => {
  const first = initial('deterministic-id-proof').state
  const second = initial('deterministic-id-proof').state
  assert.deepEqual(first, second)
  assert.equal(first.portable.format, IDENTITY_CONTRACT_VERSION)
  assert.equal(first.validation.semanticProfile, SEMANTIC_DIGEST_PROFILE)
  assert.match(first.portable.lineageId, /^urn:uuid:/)
  assert.match(first.local.fileInstanceId, /^file-instance:/)
  assert.doesNotMatch(portableBytes(first).toString('utf8'), /file-instance:/)
})
