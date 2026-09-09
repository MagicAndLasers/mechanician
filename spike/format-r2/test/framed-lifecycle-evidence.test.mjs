import assert from 'node:assert/strict'
import test from 'node:test'

import {
  DEFAULT_LARGE_PAYLOAD_BYTES,
  DEFAULT_SCALE_EVENT_COUNT,
  FRAMED_LIFECYCLE_EVIDENCE_VERSION,
  runFramedKilledWriterEvidence,
  runFramedLifecycleEvidence,
  runFramedScaleEvidence,
} from '../bindings/framed-lifecycle-evidence.mjs'

test('framed binding survives 50k events plus a bounded synthetic large boundary', {
  timeout: 30_000,
}, () => {
  const evidence = runFramedScaleEvidence()
  assert.equal(evidence.eventCountBeforeBoundary, DEFAULT_SCALE_EVENT_COUNT)
  assert.equal(evidence.eventCountAfterBoundary, DEFAULT_SCALE_EVENT_COUNT + 1)
  assert.equal(evidence.recoveredCount, DEFAULT_SCALE_EVENT_COUNT + 1)
  assert.equal(evidence.largePayloadBytes, DEFAULT_LARGE_PAYLOAD_BYTES)
  assert.ok(evidence.boundaryBytes > DEFAULT_LARGE_PAYLOAD_BYTES)
  assert.ok(evidence.publishedBytes > evidence.initialBytes)
  assert.equal(evidence.tailEventIds.at(-1), 'synthetic-large-boundary')
  assert.equal(evidence.extensionPreserved, true)
})

test('SIGKILL preserves an fsynced frame and recovery rejects only a torn tail frame', {
  timeout: 20_000,
}, async () => {
  const evidence = await runFramedKilledWriterEvidence()
  assert.deepEqual(evidence.completedFrame.processTermination, {
    code: null, signal: 'SIGKILL',
  })
  assert.equal(evidence.completedFrame.survivedRecovery, true)
  assert.equal(evidence.completedFrame.survivingEvents, 129)
  assert.deepEqual(evidence.tornFrame.processTermination, {
    code: null, signal: 'SIGKILL',
  })
  assert.equal(evidence.tornFrame.rejectedAndTruncated, true)
  assert.equal(evidence.tornFrame.survivingEvents, 129)
  assert.equal(evidence.tornFrame.lossBound, 'one-in-progress-tail-frame')
})

test('lifecycle evidence proves local mechanics and names the production gaps', () => {
  const evidence = runFramedLifecycleEvidence()
  assert.equal(evidence.format, FRAMED_LIFECYCLE_EVIDENCE_VERSION)
  assert.equal(evidence.candidate, 'framed-single-file')

  const local = evidence.localFilesystemEvidence
  assert.equal(local.externalEdit.externalEditWasJsonParseable, true)
  assert.equal(local.externalEdit.uncheckedReaderAcceptedChecksumMismatch, true)
  assert.equal(local.externalEdit.recoveryRejectedEditedFrame, true)
  assert.equal(local.externalEdit.survivingPrefixEvents, 9)
  assert.equal(local.externalEdit.suffixEventsDiscarded, 15)
  assert.equal(local.externalEdit.malformedJSONWithValidCRCAcceptedByRecovery, true)
  assert.equal(local.externalEdit.malformedJSONReadError, 'SyntaxError')
  assert.equal(local.externalEdit.oversizedDeclaredTailRejectedWithoutAllocation, true)

  assert.equal(local.rename.bytesUnchanged, true)
  assert.equal(local.rename.eventCount, 16)
  assert.equal(local.rename.sameLocalInode, true)
  assert.equal(local.rename.stalePathReadError, 'ENOENT')
  assert.equal(local.rename.staleLocatorCreatedNewFile, true)

  assert.equal(local.finderDuplicate.bytesInitiallyEqual, true)
  assert.equal(local.finderDuplicate.distinctLocalInode, true)
  assert.equal(local.finderDuplicate.writeToCopyDidNotChangeSource, true)
  assert.equal(local.finderDuplicate.sourceEvents, 16)
  assert.equal(local.finderDuplicate.copyEvents, 17)
  assert.equal(local.finderDuplicate.bindingEnforcesReadOnlyUntilFork, false)

  assert.equal(local.missingTrashDetach.missingReadError, 'ENOENT')
  assert.equal(local.missingTrashDetach.movedFileRemainedReadable, true)
  assert.equal(local.missingTrashDetach.openDescriptorFollowedTrashedInode, true)
  assert.equal(local.missingTrashDetach.appendAtMissingLocatorSilentlyRecreated, true)
  assert.equal(local.missingTrashDetach.splitRecordCount, 2)

  assert.equal(local.extensionPreservation.semanticValuePreserved, true)
  assert.equal(local.extensionPreservation.byteDigestPreservedByCurrentCanonicalCompaction, true)
  assert.equal(local.compactionReplacement.inodeReplaced, true)
  assert.equal(local.compactionReplacement.staleDescriptorAcceptedWrite, true)
  assert.equal(local.compactionReplacement.staleDescriptorWriteVisibleInPublishedPath, false)
  assert.equal(local.compactionReplacement.temporaryResidue, false)
  assert.equal(local.signatureEnvelope.envelopeRoundTrippedAsOpaqueData, true)
  assert.equal(local.signatureEnvelope.crcRecomputedTamperAccepted, true)
  assert.equal(local.signatureEnvelope.cryptographicVerificationImplemented, false)

  assert.ok(evidence.stopGaps.some((gap) => gap.includes('silently recreates')))
  assert.ok(evidence.stopGaps.some((gap) => gap.includes('signature envelope')))
  assert.ok(evidence.stopGaps.some((gap) => gap.includes('network-volume')))
})

test('scale evidence rejects accidental unbounded allocations', () => {
  assert.throws(() => runFramedScaleEvidence({ eventCount: 100_001 }), /eventCount/)
  assert.throws(() => runFramedScaleEvidence({ largePayloadBytes: 16 * 1024 * 1024 + 1 }),
    /largePayloadBytes/)
})
