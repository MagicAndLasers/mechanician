import fs from 'node:fs'
import path from 'node:path'
import { createHash, randomUUID } from 'node:crypto'

// External producers must never open library.db. They publish immutable, create-only envelopes and
// the app adopts each operation transactionally, recording operationID as its idempotency key.
//
// Payload JSON is carried as exact base64 bytes rather than an embedded object. That gives the Node
// producer and Swift adopter one byte sequence to digest; neither side has to reproduce the other
// language's dictionary ordering or number encoding before it can trust the payload.
export const AUTHORITY_INBOX_SCHEMA_VERSION = 1
export const AUTHORITY_INBOX_PROTOCOL = 'storage-authority-v1'
export const AUTHORITY_INBOX_LAUNCH_IDENTITY = 'authority-inbox-v1'
export const AUTHORITY_INBOX_DIRECTORY = 'authority-inbox'
export const AUTHORITY_INBOX_MAX_PAYLOAD_BYTES = 128 * 1024 * 1024
export const AUTHORITY_INBOX_MAX_ENVELOPE_BYTES = 192 * 1024 * 1024
export const AUTHORITY_INBOX_MAX_RETAINED_REFERENCES = 64

const SAFE_IDENTIFIER = /^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$/
const SAFE_DOMAIN = /^[a-z][a-z0-9._-]{0,63}$/
const SHA256 = /^[a-f0-9]{64}$/
const CANONICAL_TIMESTAMP = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/
const UUID = /^[a-fA-F0-9]{8}-[a-fA-F0-9]{4}-[1-8][a-fA-F0-9]{3}-[89abAB][a-fA-F0-9]{3}-[a-fA-F0-9]{12}$/

function fail(message) { throw new TypeError(`invalid authority inbox envelope: ${message}`) }

function isRecord(value) {
  return Boolean(value) && typeof value === 'object' && !Array.isArray(value)
}

function exactKeys(value, expected, label) {
  if (!isRecord(value)) fail(`${label} must be an object`)
  const actual = Object.keys(value).sort()
  const wanted = [...expected].sort()
  if (actual.length !== wanted.length || actual.some((key, index) => key !== wanted[index])) {
    fail(`${label} fields must be exactly ${wanted.join(', ')}`)
  }
}

function boundedString(value, label, maximum, pattern = null) {
  if (typeof value !== 'string' || value.length === 0 || value.length > maximum) {
    fail(`${label} must be 1–${maximum} characters`)
  }
  if (pattern && !pattern.test(value)) fail(`${label} has an unsupported value`)
  return value
}

function nonnegativeSafeInteger(value, label) {
  if (!Number.isSafeInteger(value) || value < 0) fail(`${label} must be a nonnegative safe integer`)
  return value
}

export function sha256Hex(bytes) {
  return createHash('sha256').update(bytes).digest('hex')
}

// A deliberately small canonicalizer. Envelope values have already passed the strict finite JSON
// validator below; recursively sorting object keys makes retry bytes stable even if a caller rebuilt
// the same envelope with different property insertion order.
export function canonicalJSONStringify(value) {
  if (value === null || typeof value === 'boolean' || typeof value === 'string') {
    return JSON.stringify(value)
  }
  if (typeof value === 'number') {
    if (!Number.isFinite(value)) fail('non-finite JSON number')
    return JSON.stringify(value)
  }
  if (Array.isArray(value)) return `[${value.map(canonicalJSONStringify).join(',')}]`
  if (isRecord(value)) {
    return `{${Object.keys(value).sort().map((key) =>
      `${JSON.stringify(key)}:${canonicalJSONStringify(value[key])}`).join(',')}}`
  }
  fail('payload contains a non-JSON value')
}

export function encodeAuthorityInboxPayload(value) {
  const bytes = Buffer.from(canonicalJSONStringify(value), 'utf8')
  if (bytes.length > AUTHORITY_INBOX_MAX_PAYLOAD_BYTES) {
    fail(`payload exceeds ${AUTHORITY_INBOX_MAX_PAYLOAD_BYTES} bytes; use retainedBytes`)
  }
  return {
    encoding: 'base64url-json',
    byteCount: bytes.length,
    sha256: sha256Hex(bytes),
    data: bytes.toString('base64url'),
  }
}

function validateRetainedReference(reference, operationID, seen) {
  exactKeys(reference, ['id', 'relativePath', 'byteCount', 'sha256', 'mediaType'], 'retained byte')
  const id = boundedString(reference.id, 'retained byte id', 128, SAFE_IDENTIFIER)
  if (seen.has(id)) fail(`duplicate retained byte id ${id}`)
  seen.add(id)
  const relativePath = boundedString(reference.relativePath, 'retained byte path', 512)
  if (path.isAbsolute(relativePath) || relativePath.includes('\\') || relativePath.includes('\0')) {
    fail('retained byte path must be a portable relative path')
  }
  const normalized = path.posix.normalize(relativePath)
  const expectedPrefix = `retained/${operationID}/`
  if (normalized !== relativePath || !relativePath.startsWith(expectedPrefix) ||
      relativePath.slice(expectedPrefix.length).includes('/')) {
    fail(`retained byte path must be ${expectedPrefix}<leaf>`)
  }
  nonnegativeSafeInteger(reference.byteCount, 'retained byte byteCount')
  boundedString(reference.sha256, 'retained byte sha256', 64, SHA256)
  if (reference.mediaType !== null) boundedString(reference.mediaType, 'retained byte mediaType', 255)
}

export function validateAuthorityInboxEnvelope(envelope) {
  exactKeys(envelope, [
    'schemaVersion', 'operationID', 'subjectID', 'producer', 'authority', 'domain', 'kind',
    'definitionRevision', 'createdAt', 'payload', 'retainedBytes',
  ], 'top level')
  if (envelope.schemaVersion !== AUTHORITY_INBOX_SCHEMA_VERSION) fail('unsupported schemaVersion')
  const operationID = boundedString(envelope.operationID, 'operationID', 128, SAFE_IDENTIFIER)
  boundedString(envelope.subjectID, 'subjectID', 128, SAFE_IDENTIFIER)

  exactKeys(envelope.producer, ['id', 'build'], 'producer')
  boundedString(envelope.producer.id, 'producer id', 128, SAFE_IDENTIFIER)
  boundedString(envelope.producer.build, 'producer build', 128, SAFE_IDENTIFIER)

  exactKeys(envelope.authority, ['protocol', 'observedGeneration'], 'authority')
  if (envelope.authority.protocol !== AUTHORITY_INBOX_PROTOCOL) fail('unsupported authority protocol')
  // This observation is diagnostic, never routing authority: a pending envelope must survive a
  // cutover or rollback and be adopted into whichever generation the app currently selected.
  boundedString(envelope.authority.observedGeneration, 'observed authority generation', 128, SAFE_IDENTIFIER)

  boundedString(envelope.domain, 'domain', 64, SAFE_DOMAIN)
  boundedString(envelope.kind, 'kind', 64, SAFE_DOMAIN)
  if (envelope.definitionRevision !== null) {
    boundedString(envelope.definitionRevision, 'definitionRevision', 16 * 1024)
  }
  boundedString(envelope.createdAt, 'createdAt', 20, CANONICAL_TIMESTAMP)
  const parsedCreatedAt = new Date(envelope.createdAt)
  if (Number.isNaN(parsedCreatedAt.getTime()) || canonicalTimestamp(parsedCreatedAt) !== envelope.createdAt) {
    fail('createdAt is not a real timestamp')
  }

  exactKeys(envelope.payload, ['encoding', 'byteCount', 'sha256', 'data'], 'payload')
  if (envelope.payload.encoding !== 'base64url-json') fail('unsupported payload encoding')
  const byteCount = nonnegativeSafeInteger(envelope.payload.byteCount, 'payload byteCount')
  if (byteCount > AUTHORITY_INBOX_MAX_PAYLOAD_BYTES) fail('payload exceeds byte limit')
  boundedString(envelope.payload.sha256, 'payload sha256', 64, SHA256)
  if (typeof envelope.payload.data !== 'string') fail('payload data must be base64 text')
  const payloadBytes = Buffer.from(envelope.payload.data, 'base64url')
  // Buffer.from(base64) accepts malformed/partial input. Re-encoding closes that permissive edge.
  if (payloadBytes.toString('base64url') !== envelope.payload.data) {
    fail('payload data is not canonical base64url')
  }
  if (payloadBytes.length !== byteCount) fail('payload byteCount mismatch')
  if (sha256Hex(payloadBytes) !== envelope.payload.sha256) fail('payload digest mismatch')
  let decodedPayload
  try { decodedPayload = JSON.parse(payloadBytes.toString('utf8')) }
  catch { fail('payload is not JSON') }
  if (Buffer.from(canonicalJSONStringify(decodedPayload), 'utf8').compare(payloadBytes) !== 0) {
    fail('payload JSON is not canonical')
  }

  if (!Array.isArray(envelope.retainedBytes) ||
      envelope.retainedBytes.length > AUTHORITY_INBOX_MAX_RETAINED_REFERENCES) {
    fail(`retainedBytes must contain at most ${AUTHORITY_INBOX_MAX_RETAINED_REFERENCES} references`)
  }
  const seen = new Set()
  for (const reference of envelope.retainedBytes) {
    validateRetainedReference(reference, operationID, seen)
  }
  if (envelope.domain === 'conversation' && envelope.kind === 'create') {
    boundedString(envelope.operationID, 'Conversation operationID', 36, UUID)
    boundedString(envelope.subjectID, 'Conversation subjectID', 36, UUID)
    if (!isRecord(decodedPayload) || decodedPayload.id !== envelope.subjectID) {
      fail('Conversation create subjectID must equal payload id')
    }
    if (envelope.retainedBytes.length !== 0) {
      fail('Conversation create v1 does not accept retained byte references')
    }
  }
  return { envelope, payload: decodedPayload }
}

function canonicalTimestamp(date) {
  const parsed = date instanceof Date ? date : new Date(date)
  if (Number.isNaN(parsed.getTime())) fail('createdAt is not a real timestamp')
  return parsed.toISOString().replace(/\.\d{3}Z$/, 'Z')
}

export function createAuthorityInboxEnvelope({
  operationID = randomUUID(),
  subjectID,
  producer,
  authority,
  domain,
  kind,
  definitionRevision = null,
  createdAt = new Date(),
  payload,
  retainedBytes = [],
}) {
  const envelope = {
    schemaVersion: AUTHORITY_INBOX_SCHEMA_VERSION,
    operationID,
    subjectID,
    producer,
    authority,
    domain,
    kind,
    definitionRevision,
    createdAt: canonicalTimestamp(createdAt),
    payload: encodeAuthorityInboxPayload(payload),
    retainedBytes,
  }
  validateAuthorityInboxEnvelope(envelope)
  return envelope
}

function assertPrivateDirectory(directory) {
  const stat = fs.lstatSync(directory)
  if (!stat.isDirectory() || stat.isSymbolicLink()) throw new Error(`unsafe inbox directory: ${directory}`)
  if (typeof process.getuid === 'function' && stat.uid !== process.getuid()) {
    throw new Error(`inbox directory is not owned by this user: ${directory}`)
  }
  if ((stat.mode & 0o077) !== 0) throw new Error(`inbox directory is not private: ${directory}`)
}

function ensurePrivateDirectory(parent, leaf) {
  const directory = path.join(parent, leaf)
  try { fs.mkdirSync(directory, { mode: 0o700 }) }
  catch (error) { if (error?.code !== 'EEXIST') throw error }
  assertPrivateDirectory(directory)
  return directory
}

function authorityInboxDirectories(anchorDirectory, producerID) {
  boundedString(producerID, 'producer id', 128, SAFE_IDENTIFIER)
  const anchor = fs.realpathSync(anchorDirectory)
  const root = ensurePrivateDirectory(anchor, AUTHORITY_INBOX_DIRECTORY)
  const version = ensurePrivateDirectory(root, `v${AUTHORITY_INBOX_SCHEMA_VERSION}`)
  const pending = ensurePrivateDirectory(ensurePrivateDirectory(version, 'pending'), producerID)
  const staging = ensurePrivateDirectory(ensurePrivateDirectory(version, 'staging'), producerID)
  return { root, pending, staging }
}

export function authorityInboxProducerDirectory(anchorDirectory, producerID) {
  return authorityInboxDirectories(anchorDirectory, producerID).pending
}

function stableFileIdentity(stat) {
  return [
    stat.dev, stat.ino, stat.size, stat.mode, stat.uid, stat.nlink,
    stat.mtimeMs, stat.ctimeMs,
  ].join(':')
}

function readBoundedEnvelope(file, { allowMultipleLinks = false } = {}) {
  const before = fs.lstatSync(file)
  if (!before.isFile() || before.isSymbolicLink()) throw new Error(`unsafe inbox envelope: ${file}`)
  if (!allowMultipleLinks && before.nlink !== 1) {
    const error = new Error(`inbox envelope publication is incomplete: ${file}`)
    error.code = 'EINBOXPENDING'
    throw error
  }
  if (typeof process.getuid === 'function' && before.uid !== process.getuid()) {
    throw new Error(`inbox envelope is not owned by this user: ${file}`)
  }
  if ((before.mode & 0o777) !== 0o400) throw new Error(`inbox envelope is not immutable: ${file}`)
  if (before.size > AUTHORITY_INBOX_MAX_ENVELOPE_BYTES) throw new Error('inbox envelope is too large')
  const noFollow = fs.constants.O_NOFOLLOW || 0
  const descriptor = fs.openSync(file, fs.constants.O_RDONLY | noFollow)
  try {
    const bytes = fs.readFileSync(descriptor)
    const after = fs.fstatSync(descriptor)
    if (stableFileIdentity(after) !== stableFileIdentity(before)) {
      throw new Error('inbox envelope changed while reading')
    }
    return bytes
  } finally { fs.closeSync(descriptor) }
}

export function readAuthorityInboxEnvelope(file) {
  const bytes = readBoundedEnvelope(file)
  let envelope
  try { envelope = JSON.parse(bytes.toString('utf8')) }
  catch { fail('file is not JSON') }
  return validateAuthorityInboxEnvelope(envelope)
}

// Find a producer operation that may have moved from pending to the app-owned adopted directory.
// The authority observation in the envelope remains informational; moving it never changes the
// operation bytes or their idempotency identity.
export function findAuthorityInboxEnvelope({
  anchorDirectory,
  producerID,
  operationID,
  states = ['pending', 'adopted'],
}) {
  boundedString(producerID, 'producer id', 128, SAFE_IDENTIFIER)
  boundedString(operationID, 'operationID', 128, SAFE_IDENTIFIER)
  const anchor = fs.realpathSync(anchorDirectory)
  const version = path.join(anchor, AUTHORITY_INBOX_DIRECTORY, `v${AUTHORITY_INBOX_SCHEMA_VERSION}`)
  for (let pass = 0; pass < 2; pass += 1) {
    for (const state of states) {
      if (state !== 'pending' && state !== 'adopted') fail('unsupported inbox state')
      const stateDirectory = path.join(version, state)
      const producerDirectory = path.join(stateDirectory, producerID)
      if (!fs.existsSync(producerDirectory)) continue
      assertPrivateDirectory(stateDirectory)
      assertPrivateDirectory(producerDirectory)
      const file = path.join(producerDirectory, `${operationID}.json`)
      try {
        const found = readAuthorityInboxEnvelope(file)
        if (found.envelope.operationID !== operationID || found.envelope.producer.id !== producerID) {
          throw new Error(`inbox operation identity mismatch: ${file}`)
        }
        return { ...found, state, path: file }
      } catch (error) {
        if (error?.code !== 'ENOENT') throw error
      }
    }
  }
  return null
}

// Publish is create-only. link(2), unlike rename(2), cannot replace an existing operation. A retry
// with identical canonical bytes succeeds idempotently; reusing an operationID for different bytes
// is a hard collision and never overwrites the first fact.
function unlinkStagingAliases(staging, destination, operationID) {
  const destinationStat = fs.lstatSync(destination)
  for (const leaf of fs.readdirSync(staging)) {
    if (!leaf.startsWith(`.${operationID}.`) || !leaf.endsWith('.tmp')) continue
    const candidate = path.join(staging, leaf)
    try {
      const stat = fs.lstatSync(candidate)
      if (stat.isFile() && !stat.isSymbolicLink() &&
          stat.dev === destinationStat.dev && stat.ino === destinationStat.ino) {
        fs.unlinkSync(candidate)
      }
    } catch {}
  }
}

function fsyncDirectories(directories) {
  for (const directory of directories) {
    const descriptor = fs.openSync(directory, 'r')
    try { fs.fsyncSync(descriptor) } finally { fs.closeSync(descriptor) }
  }
}

// A producer can crash after fsyncing staging or after linking pending but before unlinking staging.
// Run this under the producer's singleton scheduler lease before recovering its activeRun claims.
// A complete immutable staging file is promoted; an incomplete one is discarded so the still-live
// claim becomes an explicit interrupted run rather than being replayed after possible side effects.
export function recoverAuthorityInboxPublications({ anchorDirectory, producerID }) {
  const { pending, staging } = authorityInboxDirectories(anchorDirectory, producerID)
  let published = 0
  let completed = 0
  let discarded = 0
  for (const leaf of fs.readdirSync(staging)) {
    if (!leaf.startsWith('.') || !leaf.endsWith('.tmp')) continue
    const staged = path.join(staging, leaf)
    let bytes
    let envelope
    try {
      const stat = fs.lstatSync(staged)
      // Publication sets 0400 only after the full bytes have been fsynced. A 0600 temp is therefore
      // not a recoverable promise even when a lucky partial write happens to parse.
      if (!stat.isFile() || stat.isSymbolicLink() || (stat.mode & 0o777) !== 0o400) {
        throw new Error('incomplete staging mode')
      }
      bytes = readBoundedEnvelope(staged, { allowMultipleLinks: true })
      envelope = JSON.parse(bytes.toString('utf8'))
      validateAuthorityInboxEnvelope(envelope)
      if (envelope.producer.id !== producerID) throw new Error('staging producer mismatch')
      if (!Buffer.from(canonicalJSONStringify(envelope), 'utf8').equals(bytes)) {
        throw new Error('noncanonical staging bytes')
      }
    } catch {
      try { fs.unlinkSync(staged); discarded += 1 } catch {}
      continue
    }

    const destination = path.join(pending, `${envelope.operationID}.json`)
    try {
      fs.linkSync(staged, destination)
      published += 1
    } catch (error) {
      if (error?.code !== 'EEXIST') throw error
      const existing = readBoundedEnvelope(destination, { allowMultipleLinks: true })
      if (!existing.equals(bytes)) throw new Error(`operationID collision: ${envelope.operationID}`)
    }
    fs.unlinkSync(staged)
    completed += 1
  }
  if (published || completed || discarded) fsyncDirectories([staging, pending])
  return { published, completed, discarded }
}

export function publishAuthorityInboxEnvelope({ anchorDirectory, envelope }) {
  validateAuthorityInboxEnvelope(envelope)
  if (!anchorDirectory) throw new Error('authority inbox anchorDirectory is required')
  const { pending, staging } = authorityInboxDirectories(anchorDirectory, envelope.producer.id)
  const destination = path.join(pending, `${envelope.operationID}.json`)
  const bytes = Buffer.from(canonicalJSONStringify(envelope), 'utf8')
  if (bytes.length > AUTHORITY_INBOX_MAX_ENVELOPE_BYTES) fail('encoded envelope exceeds byte limit')
  const temporary = path.join(staging, `.${envelope.operationID}.${process.pid}.${randomUUID()}.tmp`)
  let descriptor = null
  let published = false
  try {
    descriptor = fs.openSync(temporary, 'wx', 0o600)
    fs.writeFileSync(descriptor, bytes)
    fs.fsyncSync(descriptor)
    fs.fchmodSync(descriptor, 0o400)
    fs.fsyncSync(descriptor)
    fs.closeSync(descriptor)
    descriptor = null
    try {
      fs.linkSync(temporary, destination)
      published = true
    } catch (error) {
      if (error?.code !== 'EEXIST') throw error
      const existing = readBoundedEnvelope(destination, { allowMultipleLinks: true })
      if (!existing.equals(bytes)) throw new Error(`operationID collision: ${envelope.operationID}`)
      unlinkStagingAliases(staging, destination, envelope.operationID)
    }
    fs.unlinkSync(temporary)
    if (fs.lstatSync(destination).nlink !== 1) {
      const error = new Error(`inbox envelope publication is incomplete: ${destination}`)
      error.code = 'EINBOXPENDING'
      throw error
    }
    // The adopter ignores nlink > 1. Only after the staging link is gone and both directory edits
    // are durable is the pending name a complete publication.
    fsyncDirectories([staging, pending])
    return { path: destination, status: published ? 'published' : 'alreadyPublished' }
  } catch (error) {
    if (descriptor !== null) { try { fs.closeSync(descriptor) } catch {} }
    try { fs.unlinkSync(temporary) } catch {}
    throw error
  }
}
