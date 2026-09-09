import assert from 'node:assert/strict'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { test } from 'node:test'

import {
  AUTHORITY_INBOX_LAUNCH_IDENTITY,
  AUTHORITY_INBOX_MAX_PAYLOAD_BYTES,
  AUTHORITY_INBOX_PROTOCOL,
  authorityInboxProducerDirectory,
  canonicalJSONStringify,
  createAuthorityInboxEnvelope,
  publishAuthorityInboxEnvelope,
  readAuthorityInboxEnvelope,
  recoverAuthorityInboxPublications,
  validateAuthorityInboxEnvelope,
} from '../src/authority-inbox-envelope.mjs'

function fixtureRoot(t) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'mechanician-authority-inbox-'))
  fs.chmodSync(root, 0o700)
  t.after(() => fs.rmSync(root, { recursive: true, force: true }))
  return fs.realpathSync(root)
}

function fixtureEnvelope(overrides = {}) {
  const operationID = overrides.operationID || '11111111-2222-4333-8444-555555555555'
  const subjectID = overrides.subjectID || 'AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE'
  return createAuthorityInboxEnvelope({
    operationID,
    subjectID,
    producer: { id: 'ambientd', build: `0.24.0-208-${AUTHORITY_INBOX_LAUNCH_IDENTITY}` },
    authority: { protocol: AUTHORITY_INBOX_PROTOCOL, observedGeneration: 'legacy-unmarked' },
    domain: 'conversation',
    kind: 'create',
    definitionRevision: 'definition-revision-7',
    createdAt: new Date('2026-08-05T12:34:56Z'),
    payload: overrides.payload || { id: subjectID, title: 'Background result', messages: [] },
    retainedBytes: overrides.retainedBytes || [],
  })
}

test('Conversation envelope carries exact digestable payload bytes and provenance', () => {
  const envelope = fixtureEnvelope()
  const decoded = validateAuthorityInboxEnvelope(envelope)
  assert.deepEqual(decoded.payload, {
    id: 'AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE',
    messages: [],
    title: 'Background result',
  })
  assert.equal(envelope.payload.encoding, 'base64url-json')
  assert.equal(envelope.payload.data.includes('='), false)
  assert.equal(envelope.producer.id, 'ambientd')
  assert.equal(envelope.authority.protocol, 'storage-authority-v1')
  assert.equal(envelope.authority.observedGeneration, 'legacy-unmarked')
  assert.equal(envelope.definitionRevision, 'definition-revision-7')
  assert.equal(envelope.createdAt, '2026-08-05T12:34:56Z')
  assert.equal(AUTHORITY_INBOX_MAX_PAYLOAD_BYTES, 128 * 1024 * 1024)
})

test('publication is create-only, private, durable, and idempotent for identical retry bytes', (t) => {
  const root = fixtureRoot(t)
  const envelope = fixtureEnvelope()
  const first = publishAuthorityInboxEnvelope({ anchorDirectory: root, envelope })
  assert.equal(first.status, 'published')
  assert.equal(first.path, path.join(
    root, 'authority-inbox', 'v1', 'pending', 'ambientd', `${envelope.operationID}.json`))
  const stat = fs.lstatSync(first.path)
  assert.equal(stat.mode & 0o777, 0o400)
  assert.equal(stat.nlink, 1)
  assert.equal(fs.statSync(path.dirname(first.path)).mode & 0o777, 0o700)
  assert.deepEqual(readAuthorityInboxEnvelope(first.path).payload,
    { id: envelope.subjectID, messages: [], title: 'Background result' })

  const second = publishAuthorityInboxEnvelope({ anchorDirectory: root, envelope })
  assert.equal(second.status, 'alreadyPublished')
  assert.equal(fs.lstatSync(first.path).nlink, 1)
})

test('operationID collision never replaces the first published fact', (t) => {
  const root = fixtureRoot(t)
  const first = fixtureEnvelope()
  const publication = publishAuthorityInboxEnvelope({ anchorDirectory: root, envelope: first })
  const original = fs.readFileSync(publication.path)
  const collision = fixtureEnvelope({
    payload: { id: first.subjectID, title: 'Different result', messages: [] },
  })
  assert.throws(
    () => publishAuthorityInboxEnvelope({ anchorDirectory: root, envelope: collision }),
    /operationID collision/)
  assert.deepEqual(fs.readFileSync(publication.path), original)
})

test('retry completes a crash-left hard link before the adopter may consume it', (t) => {
  const root = fixtureRoot(t)
  const envelope = fixtureEnvelope()
  const result = publishAuthorityInboxEnvelope({ anchorDirectory: root, envelope })
  const staging = path.join(root, 'authority-inbox', 'v1', 'staging', 'ambientd')
  const stranded = path.join(staging, `.${envelope.operationID}.old-process.fixture.tmp`)
  fs.linkSync(result.path, stranded)
  assert.equal(fs.lstatSync(result.path).nlink, 2)
  assert.throws(
    () => readAuthorityInboxEnvelope(result.path),
    (error) => error?.code === 'EINBOXPENDING')

  assert.equal(
    publishAuthorityInboxEnvelope({ anchorDirectory: root, envelope }).status,
    'alreadyPublished')
  assert.equal(fs.existsSync(stranded), false)
  assert.equal(fs.lstatSync(result.path).nlink, 1)
})

test('producer startup completes a crash-left pending link before claim recovery', (t) => {
  const root = fixtureRoot(t)
  const envelope = fixtureEnvelope()
  const result = publishAuthorityInboxEnvelope({ anchorDirectory: root, envelope })
  const staging = path.join(root, 'authority-inbox', 'v1', 'staging', 'ambientd')
  const stranded = path.join(staging, `.${envelope.operationID}.dead-process.fixture.tmp`)
  fs.linkSync(result.path, stranded)
  assert.equal(fs.lstatSync(result.path).nlink, 2)

  assert.deepEqual(recoverAuthorityInboxPublications({
    anchorDirectory: root, producerID: 'ambientd',
  }), { published: 0, completed: 1, discarded: 0 })
  assert.equal(fs.existsSync(stranded), false)
  assert.equal(fs.lstatSync(result.path).nlink, 1)
  assert.equal(readAuthorityInboxEnvelope(result.path).envelope.operationID, envelope.operationID)
})

test('producer startup promotes a fully fsynced staging file left before link', (t) => {
  const root = fixtureRoot(t)
  const envelope = fixtureEnvelope()
  const pending = authorityInboxProducerDirectory(root, 'ambientd')
  const staging = path.join(root, 'authority-inbox', 'v1', 'staging', 'ambientd')
  const staged = path.join(staging, `.${envelope.operationID}.dead-process.fixture.tmp`)
  fs.writeFileSync(staged, canonicalJSONStringify(envelope), { mode: 0o400 })
  fs.chmodSync(staged, 0o400)

  assert.deepEqual(recoverAuthorityInboxPublications({
    anchorDirectory: root, producerID: 'ambientd',
  }), { published: 1, completed: 1, discarded: 0 })
  const destination = path.join(pending, `${envelope.operationID}.json`)
  assert.equal(fs.existsSync(staged), false)
  assert.equal(fs.lstatSync(destination).nlink, 1)
  assert.equal(readAuthorityInboxEnvelope(destination).payload.id, envelope.subjectID)
})

test('producer startup discards a pre-fsync staging file instead of replaying uncertain work', (t) => {
  const root = fixtureRoot(t)
  authorityInboxProducerDirectory(root, 'ambientd')
  const staging = path.join(root, 'authority-inbox', 'v1', 'staging', 'ambientd')
  const staged = path.join(staging, '.uncertain.tmp')
  fs.writeFileSync(staged, '{"partial":', { mode: 0o600 })

  assert.deepEqual(recoverAuthorityInboxPublications({
    anchorDirectory: root, producerID: 'ambientd',
  }), { published: 0, completed: 0, discarded: 1 })
  assert.equal(fs.existsSync(staged), false)
})

test('payload mutation, noncanonical encoding, and unknown fields fail closed', () => {
  const digestMismatch = structuredClone(fixtureEnvelope())
  digestMismatch.payload.data = Buffer.from('{"id":"different"}').toString('base64url')
  assert.throws(() => validateAuthorityInboxEnvelope(digestMismatch), /byteCount mismatch|digest mismatch/)

  const padded = structuredClone(fixtureEnvelope())
  padded.payload.data += '='
  assert.throws(() => validateAuthorityInboxEnvelope(padded), /canonical base64url/)

  const unknown = structuredClone(fixtureEnvelope())
  unknown.routingHint = 'library.db'
  assert.throws(() => validateAuthorityInboxEnvelope(unknown), /top level fields must be exactly/)

  const impossibleDate = structuredClone(fixtureEnvelope())
  impossibleDate.createdAt = '2026-02-31T12:34:56Z'
  assert.throws(() => validateAuthorityInboxEnvelope(impossibleDate), /not a real timestamp/)
})

test('Conversation create binds subject identity and excludes retained bytes in v1', () => {
  assert.throws(
    () => fixtureEnvelope({ payload: { id: 'DIFFERENT', messages: [] } }),
    /subjectID must equal payload id/)
  assert.throws(
    () => fixtureEnvelope({ retainedBytes: [{
      id: 'blob-1',
      relativePath: 'retained/11111111-2222-4333-8444-555555555555/blob-1',
      byteCount: 3,
      sha256: '0'.repeat(64),
      mediaType: 'application/octet-stream',
    }] }),
    /does not accept retained byte references/)
})

test('generic retained-byte references are bounded and traversal-safe', () => {
  const envelope = createAuthorityInboxEnvelope({
    operationID: 'op-2', subjectID: 'artifact-2',
    producer: { id: 'fixture', build: '1.0.0' },
    authority: { protocol: AUTHORITY_INBOX_PROTOCOL, observedGeneration: 'sqlite-activation-7' },
    domain: 'artifact', kind: 'create', createdAt: new Date('2026-08-05T12:34:56Z'),
    payload: { id: 'artifact-2' },
    retainedBytes: [{
      id: 'body', relativePath: 'retained/op-2/body', byteCount: 100,
      sha256: 'a'.repeat(64), mediaType: 'text/markdown',
    }],
  })
  assert.equal(validateAuthorityInboxEnvelope(envelope).envelope.retainedBytes.length, 1)

  const traversal = structuredClone(envelope)
  traversal.retainedBytes[0].relativePath = 'retained/op-2/../outside'
  assert.throws(() => validateAuthorityInboxEnvelope(traversal), /retained byte path/)
})

test('publisher refuses symlinked or non-private inbox directories', (t) => {
  const root = fixtureRoot(t)
  const outside = fixtureRoot(t)
  fs.mkdirSync(path.join(root, 'authority-inbox'), { mode: 0o700 })
  fs.symlinkSync(outside, path.join(root, 'authority-inbox', 'v1'))
  assert.throws(
    () => publishAuthorityInboxEnvelope({ anchorDirectory: root, envelope: fixtureEnvelope() }),
    /unsafe inbox directory/)
})

test('canonical envelope JSON is stable across insertion order', () => {
  assert.equal(
    canonicalJSONStringify({ z: 1, a: { y: 2, x: 3 } }),
    canonicalJSONStringify({ a: { x: 3, y: 2 }, z: 1 }))
})

test('producer directory helper returns only the pending producer directory', (t) => {
  const root = fixtureRoot(t)
  assert.equal(
    authorityInboxProducerDirectory(root, 'ambientd'),
    path.join(root, 'authority-inbox', 'v1', 'pending', 'ambientd'))
})
