// Local, deterministic format-review evidence for the selected framed single-file binding.
//
// This deliberately distinguishes properties proven by ordinary local filesystem behavior from
// requirements that the naive R2 primitive does not implement. In particular, passing this
// harness does NOT claim network-volume durability, File Provider convergence, two-device
// conflict handling, cryptographic authenticity, writer coordination, or directory durability.
import crypto from 'node:crypto'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { spawn } from 'node:child_process'
import { fileURLToPath } from 'node:url'
import { performance } from 'node:perf_hooks'
import { createFramed, crc32 } from './binding-framed.mjs'

export const FRAMED_LIFECYCLE_EVIDENCE_VERSION = 'format-review-framed-lifecycle/1'
export const DEFAULT_SCALE_EVENT_COUNT = 50_000
export const DEFAULT_LARGE_PAYLOAD_BYTES = 8 * 1024 * 1024

const MODULE_DIRECTORY = path.dirname(fileURLToPath(import.meta.url))
const KILL_WRITER = path.join(MODULE_DIRECTORY, 'framed-kill-writer.mjs')
const MAX_SCALE_EVENTS = 100_000
const MAX_LARGE_PAYLOAD_BYTES = 16 * 1024 * 1024

function invariant(condition, message) {
  if (!condition) throw new Error(`framed lifecycle evidence invariant failed: ${message}`)
}

function scratch() {
  return fs.mkdtempSync(path.join(fs.realpathSync(os.tmpdir()), 'r2-framed-lifecycle-'))
}

function digest(filePath) {
  return crypto.createHash('sha256').update(fs.readFileSync(filePath)).digest('hex')
}

function encodePayload(payload) {
  const header = Buffer.alloc(8)
  header.writeUInt32LE(payload.length, 0)
  header.writeUInt32LE(crc32(payload), 4)
  return Buffer.concat([header, payload])
}

function encodeFrame(event) {
  return encodePayload(Buffer.from(JSON.stringify(event)))
}

function event(index) {
  return {
    kind: index % 2 === 0 ? 'message' : 'tool_result',
    agentId: index % 7 === 0 ? `agent-${index % 31}` : 'root',
    eventId: `event-${String(index).padStart(6, '0')}`,
    text: `payload-${String(index).padStart(6, '0')}`,
  }
}

function errorCode(operation) {
  try {
    operation()
    return null
  } catch (error) {
    return error?.code ?? error?.name ?? 'UNKNOWN'
  }
}

function frameOffsets(buffer) {
  const offsets = []
  let offset = 0
  while (offset + 8 <= buffer.length) {
    const length = buffer.readUInt32LE(offset)
    if (offset + 8 + length > buffer.length) break
    offsets.push({ header: offset, payload: offset + 8, length })
    offset += 8 + length
  }
  return offsets
}

function waitForReady(child, expectedMode) {
  return new Promise((resolve, reject) => {
    let output = ''
    let errors = ''
    const timeout = setTimeout(() => {
      child.kill('SIGKILL')
      reject(new Error(`crash injector timed out (${expectedMode})`))
    }, 5_000)
    child.stdout.setEncoding('utf8')
    child.stderr.setEncoding('utf8')
    child.stdout.on('data', (chunk) => {
      output += chunk
      if (!output.includes(`READY ${expectedMode} `)) return
      clearTimeout(timeout)
      resolve(output.trim())
    })
    child.stderr.on('data', (chunk) => { errors += chunk })
    child.once('error', (error) => {
      clearTimeout(timeout)
      reject(error)
    })
    child.once('exit', (code, signal) => {
      if (output.includes(`READY ${expectedMode} `)) return
      clearTimeout(timeout)
      reject(new Error(
        `crash injector exited before ready: code=${code} signal=${signal} stderr=${errors}`))
    })
  })
}

async function killedAppend(filePath, mode) {
  const child = spawn(process.execPath, [KILL_WRITER, mode, filePath], {
    stdio: ['ignore', 'pipe', 'pipe'],
  })
  const ready = await waitForReady(child, mode)
  const closed = new Promise((resolve, reject) => {
    const timeout = setTimeout(() => reject(new Error(`SIGKILL did not stop ${mode} child`)), 5_000)
    child.once('close', (code, signal) => {
      clearTimeout(timeout)
      resolve({ code, signal })
    })
  })
  invariant(child.kill('SIGKILL'), `could not kill ${mode} crash injector`)
  const termination = await closed
  invariant(termination.code == null && termination.signal === 'SIGKILL',
    `${mode} injector did not terminate by SIGKILL`)
  return { ready, termination }
}

export function runFramedScaleEvidence({
  eventCount = DEFAULT_SCALE_EVENT_COUNT,
  largePayloadBytes = DEFAULT_LARGE_PAYLOAD_BYTES,
} = {}) {
  invariant(Number.isSafeInteger(eventCount) && eventCount > 0
    && eventCount <= MAX_SCALE_EVENTS, `eventCount must be 1...${MAX_SCALE_EVENTS}`)
  invariant(Number.isSafeInteger(largePayloadBytes) && largePayloadBytes > 0
    && largePayloadBytes <= MAX_LARGE_PAYLOAD_BYTES,
  `largePayloadBytes must be 1...${MAX_LARGE_PAYLOAD_BYTES}`)

  const directory = scratch()
  const file = path.join(directory, 'scale.convrec-frames')
  const binding = createFramed(file)
  const started = performance.now()
  try {
    const initial = Array.from({ length: eventCount }, (_, index) => event(index))
    const initialBytes = binding.build(initial)
    const boundaryBytes = binding.commitBoundary({
      kind: 'artifact',
      agentId: 'root',
      eventId: 'synthetic-large-boundary',
      mediaType: 'application/octet-stream',
      retainedBytesBase64Shape: 'x'.repeat(largePayloadBytes),
      extensions: {
        'org.mechanician.scale-proof': { version: 1, preserved: true },
      },
    })
    const recoveredCount = binding.recover()
    const tail = binding.openTail(2)
    const decoded = binding.fullDecode()
    invariant(recoveredCount === eventCount + 1, 'scale recovery count drifted')
    invariant(decoded.length === eventCount + 1, 'scale full decode count drifted')
    invariant(tail.at(-1)?.eventId === 'synthetic-large-boundary',
      'scale tail omitted the large boundary')
    return {
      eventCountBeforeBoundary: eventCount,
      eventCountAfterBoundary: decoded.length,
      largePayloadBytes,
      initialBytes,
      boundaryBytes,
      publishedBytes: fs.statSync(file).size,
      recoveredCount,
      tailEventIds: tail.map((item) => item.eventId),
      extensionPreserved: tail.at(-1)?.extensions?.['org.mechanician.scale-proof']?.preserved
        === true,
      elapsedMilliseconds: Math.round((performance.now() - started) * 100) / 100,
    }
  } finally {
    fs.rmSync(directory, { recursive: true, force: true })
  }
}

export async function runFramedKilledWriterEvidence() {
  const directory = scratch()
  const file = path.join(directory, 'killed-writer.convrec-frames')
  const binding = createFramed(file)
  try {
    binding.build(Array.from({ length: 128 }, (_, index) => event(index)))
    const committed = await killedAppend(file, 'committed')
    const committedSize = fs.statSync(file).size
    const committedSurvivors = binding.recover()
    invariant(committedSurvivors === 129, 'fsynced frame did not survive writer death')
    invariant(binding.openTail(1)[0]?.toolUseId === 'killed-after-fsync',
      'fsynced frame was not the recovered tail')

    const torn = await killedAppend(file, 'torn')
    invariant(fs.statSync(file).size > committedSize, 'torn injector appended no bytes')
    const tornSurvivors = binding.recover()
    invariant(tornSurvivors === 129, 'torn append damaged completed frames')
    invariant(fs.statSync(file).size === committedSize,
      'recovery did not truncate exactly the torn suffix')
    return {
      completedFrame: {
        processTermination: committed.termination,
        survivedRecovery: true,
        survivingEvents: committedSurvivors,
      },
      tornFrame: {
        processTermination: torn.termination,
        rejectedAndTruncated: true,
        survivingEvents: tornSurvivors,
        lossBound: 'one-in-progress-tail-frame',
      },
    }
  } finally {
    fs.rmSync(directory, { recursive: true, force: true })
  }
}

function externalEditEvidence(directory) {
  const file = path.join(directory, 'external-edit.convrec-frames')
  const binding = createFramed(file)
  binding.build(Array.from({ length: 24 }, (_, index) => event(index)))
  const bytes = fs.readFileSync(file)
  const offsets = frameOffsets(bytes)
  const corruptIndex = 9
  const target = Buffer.from('payload-000009')
  const frame = offsets[corruptIndex]
  const withinFrame = bytes.subarray(frame.payload, frame.payload + frame.length).indexOf(target)
  invariant(withinFrame >= 0, 'external-edit target not found')
  bytes[frame.payload + withinFrame + target.length - 1] = '8'.charCodeAt(0)
  fs.writeFileSync(file, bytes)

  // The naive R2 reader does not validate checksums. Record this as a gap rather than laundering
  // a successful JSON parse into an integrity claim.
  const uncheckedValue = binding.fullDecode()[corruptIndex].text
  const survivors = binding.recover()
  invariant(survivors === corruptIndex, 'recovery trusted or skipped an invalid interior frame')
  invariant(binding.fullDecode().length === corruptIndex,
    'events after an invalid interior frame survived without a chain/index proof')
  const validPrefixBytes = fs.statSync(file).size

  // CRC says only that bytes arrived unchanged. A syntactically invalid JSON payload with the
  // right CRC passes the primitive's recovery scan and fails later in the unchecked reader.
  fs.appendFileSync(file, encodePayload(Buffer.from('{"frameType":')))
  const malformedAcceptedByRecovery = binding.recover() === corruptIndex + 1
  const malformedReadError = errorCode(() => binding.fullDecode())
  fs.truncateSync(file, validPrefixBytes)

  // A hostile four-byte length cannot force allocation: the scan treats the impossible payload as
  // a torn suffix and returns to the same valid prefix.
  const hostileHeader = Buffer.alloc(8)
  hostileHeader.writeUInt32LE(0xffffffff, 0)
  hostileHeader.writeUInt32LE(0, 4)
  fs.appendFileSync(file, hostileHeader)
  const oversizedDeclaredTailRejected = binding.recover() === corruptIndex
    && fs.statSync(file).size === validPrefixBytes
  return {
    externalEditWasJsonParseable: uncheckedValue === 'payload-000008',
    uncheckedReaderAcceptedChecksumMismatch: true,
    recoveryRejectedEditedFrame: true,
    survivingPrefixEvents: survivors,
    suffixEventsDiscarded: 24 - survivors,
    malformedJSONWithValidCRCAcceptedByRecovery: malformedAcceptedByRecovery,
    malformedJSONReadError: malformedReadError,
    oversizedDeclaredTailRejectedWithoutAllocation: oversizedDeclaredTailRejected,
    productionRequirement:
      'validate bounds, CRC, JSON, and schema before exposing a frame; surface conflict before truncating an externally edited file',
  }
}

function renameAndDuplicateEvidence(directory) {
  const original = path.join(directory, 'record.convrec-frames')
  const renamed = path.join(directory, 'renamed.convrec-frames')
  const duplicate = path.join(directory, 'renamed copy.convrec-frames')
  const originalBinding = createFramed(original)
  originalBinding.build(Array.from({ length: 16 }, (_, index) => event(index)))
  const before = digest(original)
  const originalInode = fs.statSync(original).ino
  fs.renameSync(original, renamed)
  const renamedBinding = createFramed(renamed)
  const renamedHash = digest(renamed)
  const oldPathReadError = errorCode(() => originalBinding.fullDecode())

  // The benchmark writer uses 'a', which silently recreates a missing old locator. This is an R2
  // prototype gap: a production writer must open without O_CREAT and bind writes to a registered
  // file instance/version.
  originalBinding.commitBoundary({ kind: 'message', eventId: 'stale-locator-split' })
  const staleLocatorCreatedNewFile = fs.existsSync(original)
    && originalBinding.fullDecode().length === 1
  fs.rmSync(original, { force: true })

  fs.copyFileSync(renamed, duplicate)
  const duplicateBinding = createFramed(duplicate)
  const duplicateBefore = digest(duplicate)
  const duplicateInode = fs.statSync(duplicate).ino
  duplicateBinding.commitBoundary({ kind: 'message', eventId: 'duplicate-only-append' })
  const originalAfterDuplicateWrite = digest(renamed)
  return {
    rename: {
      bytesUnchanged: before === renamedHash,
      eventCount: renamedBinding.fullDecode().length,
      sameLocalInode: originalInode === fs.statSync(renamed).ino,
      stalePathReadError: oldPathReadError,
      staleLocatorCreatedNewFile,
    },
    finderDuplicate: {
      bytesInitiallyEqual: renamedHash === duplicateBefore,
      distinctLocalInode: fs.statSync(renamed).ino !== duplicateInode,
      writeToCopyDidNotChangeSource: originalAfterDuplicateWrite === renamedHash,
      sourceEvents: renamedBinding.fullDecode().length,
      copyEvents: duplicateBinding.fullDecode().length,
      bindingEnforcesReadOnlyUntilFork: false,
      productionRequirement:
        'assign a private file instance and keep an unregistered duplicate read-only until explicit fork/adoption',
    },
  }
}

function missingTrashAndDetachEvidence(directory) {
  const live = path.join(directory, 'trash-source.convrec-frames')
  const trashDirectory = path.join(directory, '.Trash')
  const trashed = path.join(trashDirectory, 'trash-source.convrec-frames')
  fs.mkdirSync(trashDirectory)
  const binding = createFramed(live)
  binding.build(Array.from({ length: 12 }, (_, index) => event(index)))
  const descriptor = fs.openSync(live, 'a')
  fs.renameSync(live, trashed)
  const missingReadError = errorCode(() => binding.fullDecode())

  // An already-open descriptor remains attached to the renamed inode. This is ordinary POSIX
  // behavior and the reason compaction/trash needs a writer lease plus vnode coordination.
  fs.writeSync(descriptor, encodeFrame({ kind: 'message', eventId: 'write-after-trash' }))
  fs.fsyncSync(descriptor)
  fs.closeSync(descriptor)
  const trashedBinding = createFramed(trashed)
  const trashedEventsAfterDetachedWrite = trashedBinding.recover()

  binding.commitBoundary({ kind: 'message', eventId: 'split-at-missing-locator' })
  const recreatedEvents = binding.fullDecode().length
  return {
    missingReadError,
    movedFileRemainedReadable: trashedBinding.fullDecode().length === 13,
    openDescriptorFollowedTrashedInode: trashedEventsAfterDetachedWrite === 13,
    appendAtMissingLocatorSilentlyRecreated: recreatedEvents === 1,
    splitRecordCount: 2,
    productionRequirement:
      'open without create, stop writes on rename/delete, retain a visible missing registration, and require explicit Locate or fork recovery',
  }
}

function extensionsCompactionAndSignatureEvidence(directory) {
  const file = path.join(directory, 'extensions.convrec-frames')
  const binding = createFramed(file)
  const extended = {
    kind: 'record_head',
    lineageId: 'urn:uuid:00000000-0000-4000-8000-000000000001',
    versionId: 'urn:uuid:00000000-0000-4000-8000-000000000002',
    extensions: {
      'org.example.future': {
        version: 7,
        nested: [null, true, 42, { opaque: 'preserve exactly as JSON values' }],
      },
    },
    signatureEnvelope: {
      algorithm: 'Ed25519',
      keyId: 'fixture-key',
      signature: 'fixture-not-cryptographically-verified',
    },
  }
  binding.build([extended, event(1), event(2)])
  const beforeBytes = fs.readFileSync(file)
  const beforeDigest = digest(file)
  const beforeInode = fs.statSync(file).ino
  const staleDescriptor = fs.openSync(file, 'a')
  binding.compact()
  const afterInode = fs.statSync(file).ino
  const afterDigest = digest(file)
  const decoded = binding.fullDecode()

  fs.writeSync(staleDescriptor,
    encodeFrame({ kind: 'message', eventId: 'lost-through-stale-pre-compaction-descriptor' }))
  fs.fsyncSync(staleDescriptor)
  const staleDescriptorSize = fs.fstatSync(staleDescriptor).size
  fs.closeSync(staleDescriptor)
  const publishedCountAfterStaleWrite = binding.fullDecode().length

  // A CRC is accidental-corruption detection, not authenticity. Replace a same-length value and
  // recompute CRC exactly as a malicious editor can; recovery necessarily accepts it because no
  // cryptographic verification exists in this primitive.
  const tampered = fs.readFileSync(file)
  const first = frameOffsets(tampered)[0]
  const payload = tampered.subarray(first.payload, first.payload + first.length)
  const needle = Buffer.from('fixture-key')
  const at = payload.indexOf(needle)
  invariant(at >= 0, 'signature tamper target not found')
  Buffer.from('intruderkey').copy(payload, at) // same byte length
  tampered.writeUInt32LE(crc32(payload), first.header + 4)
  fs.writeFileSync(file, tampered)
  const accepted = binding.recover()
  const tamperedKey = binding.fullDecode()[0].signatureEnvelope.keyId

  return {
    extensionPreservation: {
      semanticValuePreserved: JSON.stringify(decoded[0]) === JSON.stringify(extended),
      byteDigestPreservedByCurrentCanonicalCompaction: beforeDigest === afterDigest,
      byteLengthPreserved: beforeBytes.length === fs.statSync(file).size,
    },
    compactionReplacement: {
      inodeReplaced: beforeInode !== afterInode,
      staleDescriptorAcceptedWrite: staleDescriptorSize > beforeBytes.length,
      staleDescriptorWriteVisibleInPublishedPath: publishedCountAfterStaleWrite !== 3,
      temporaryResidue: fs.existsSync(`${file}.tmp`),
      productionRequirement:
        'exclusive writer lease, generation check, file+directory durability, and conflict-safe replacement',
    },
    signatureEnvelope: {
      envelopeRoundTrippedAsOpaqueData: decoded[0].signatureEnvelope.keyId === 'fixture-key',
      crcRecomputedTamperAccepted: accepted === 3 && tamperedKey === 'intruderkey',
      cryptographicVerificationImplemented: false,
      productionRequirement:
        'define canonical signed bytes and verify the signature envelope independently of CRC before trust or rewrite',
    },
  }
}

export function runFramedLifecycleEvidence() {
  const directory = scratch()
  try {
    const externalEdit = externalEditEvidence(directory)
    const fileOperations = renameAndDuplicateEvidence(directory)
    const missingTrashDetach = missingTrashAndDetachEvidence(directory)
    const preservation = extensionsCompactionAndSignatureEvidence(directory)
    return {
      format: FRAMED_LIFECYCLE_EVIDENCE_VERSION,
      candidate: 'framed-single-file',
      localFilesystemEvidence: {
        externalEdit,
        ...fileOperations,
        missingTrashDetach,
        ...preservation,
      },
      provenLocally: [
        'complete prefix recovery after torn or checksum-invalid suffix',
        'fail-closed truncation at the first checksum-invalid interior frame',
        'byte-preserving same-volume rename and independent Finder-style copy bytes',
        'unknown JSON extension values survive current decode-and-compact behavior',
        'atomic path replacement isolates the published path from a stale descriptor',
      ],
      stopGaps: [
        'the naive reader exposes JSON before validating frame CRC',
        'recovery validates frame CRC but not JSON syntax or record semantics',
        'append mode silently recreates missing or stale locators',
        'the binding alone cannot identify or fence a Finder duplicate before fork',
        'an open writer descriptor can continue writing a trashed or pre-compaction inode',
        'no exclusive writer lease or generation fence is implemented',
        'CRC does not authenticate a signature envelope or maliciously rewritten bytes',
        'directory fsync/F_FULLFSYNC and post-crash rename durability are not proven',
        'network-volume, File Provider convergence, and two-device conflict behavior are unproven',
      ],
    }
  } finally {
    fs.rmSync(directory, { recursive: true, force: true })
  }
}
