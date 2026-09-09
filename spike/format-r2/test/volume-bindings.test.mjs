import test from 'node:test'
import assert from 'node:assert/strict'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { canonicalFromSidecar } from '../canonical-from-sidecar.mjs'
import {
  DETERMINISTIC_VOLUME_FIXTURE,
  makeRunID,
  parseArguments,
  runVolumeHarness,
  validateSanitizedFixture,
  validateVolumeRoot,
} from '../bindings/volume-bindings.mjs'
import { FORMAT_EVIDENCE_REPOSITORY_ENV } from '../external-evidence-repository.mjs'

// This checked-in synthetic sidecar deliberately exercises the production-seed adapter without
// making public CI depend on an external reviewed corpus. Manual paired-volume runs can still
// select a reviewed derivative from an explicitly configured evidence checkout.
const fixture = DETERMINISTIC_VOLUME_FIXTURE

function scratchRoot() {
  return fs.mkdtempSync(path.join(fs.realpathSync(os.tmpdir()), 'mechanician-volume-test-'))
}

function expectedEventCount() {
  const source = JSON.parse(fs.readFileSync(fixture, 'utf8'))
  return canonicalFromSidecar(source).events.length
}

function assertAllocationSnapshot(snapshot) {
  assert.ok(snapshot.fileCount > 0)
  assert.ok(snapshot.logicalBytes > 0)
  if (snapshot.allocatedBytesAvailable) {
    assert.ok(snapshot.allocatedBytes > 0)
  } else {
    assert.equal(snapshot.allocatedBytes, null)
  }
}

test('argument parsing requires explicit root and reviewed fixture and rejects ambiguity', () => {
  assert.deepEqual(
    parseArguments(['--root', '/dedicated', '--fixture', '/fixture.json', '--retain']),
    { root: '/dedicated', fixture: '/fixture.json', retain: true },
  )
  assert.throws(() => parseArguments([]), /Missing required --root/)
  assert.throws(() => parseArguments(['--root', '/dedicated']), /Missing required --fixture/)
  assert.throws(
    () => parseArguments(['--root', '/one', '--root', '/two', '--fixture', '/fixture.json']),
    /Duplicate argument/,
  )
  assert.throws(
    () => parseArguments(['--root', '/one', '--fixture', '/fixture.json', '--surprise']),
    /Unknown argument/,
  )
})

test('run IDs combine a UTC timestamp with a unique identifier', () => {
  assert.equal(
    makeRunID(new Date('2026-08-03T12:34:56.789Z'), '11111111-2222-4333-8444-555555555555'),
    'mechanician-volume-20260803T123456Z-11111111-2222-4333-8444-555555555555',
  )
})

test('repository fixture exercises ordered dialog, tool, compaction, and interaction events', () => {
  const source = JSON.parse(fs.readFileSync(fixture, 'utf8'))
  const canonical = canonicalFromSidecar(source)
  assert.equal(canonical.chronology.status, 'complete')
  assert.equal(canonical.events.length, 10)
  assert.deepEqual(new Set(canonical.events.map((event) => event.kind)), new Set([
    'user_message',
    'assistant_message',
    'tool_call',
    'tool_result',
    'compaction',
    'authorization_request',
    'authorization_response',
    'question',
    'answer',
  ]))
})

test('root and fixture validation reject broad paths, symlinks, and non-reviewed input', () => {
  const root = scratchRoot()
  const parent = path.dirname(root)
  const symlink = path.join(parent, `mechanician-volume-link-${process.pid}-${Date.now()}`)
  const outsideFixture = path.join(root, 'not-sanitized.json')
  fs.writeFileSync(outsideFixture, '{}')
  fs.symlinkSync(root, symlink)
  try {
    assert.equal(validateVolumeRoot(root), root)
    assert.equal(validateSanitizedFixture(fixture), fixture)
    assert.throws(() => validateVolumeRoot('/'), /Refusing broad/)
    assert.throws(() => validateVolumeRoot(os.homedir()), /Refusing broad/)
    assert.throws(() => validateVolumeRoot(path.dirname(fixture)), /overlaps protected/)
    assert.throws(() => validateVolumeRoot(symlink), /must not contain symlinks/)
    assert.throws(
      () => validateSanitizedFixture(outsideFixture),
      new RegExp(FORMAT_EVIDENCE_REPOSITORY_ENV),
    )
    assert.throws(
      () => validateSanitizedFixture(
        path.join(path.dirname(fixture), '../../bindings/volume-bindings.mjs'),
      ),
      new RegExp(FORMAT_EVIDENCE_REPOSITORY_ENV),
    )
  } finally {
    fs.rmSync(symlink, { force: true })
    fs.rmSync(root, { recursive: true, force: true })
  }
})

test('reviewed external fixtures require an explicit evidence checkout', () => {
  const evidenceRoot = fs.mkdtempSync(path.join(fs.realpathSync(os.tmpdir()), 'mech-evidence-'))
  const corpusRoot = path.join(evidenceRoot, 'docs/mechanician/agent-document-format/corpus')
  fs.mkdirSync(corpusRoot, { recursive: true })
  const reviewedFixture = path.join(corpusRoot, 'activity-heavy.json')
  const unreviewedFixture = path.join(corpusRoot, 'unreviewed.json')
  fs.writeFileSync(reviewedFixture, '{}')
  fs.writeFileSync(unreviewedFixture, '{}')
  const environment = { [FORMAT_EVIDENCE_REPOSITORY_ENV]: evidenceRoot }
  try {
    assert.equal(validateSanitizedFixture(reviewedFixture, environment), reviewedFixture)
    assert.throws(
      () => validateSanitizedFixture(unreviewedFixture, environment),
      /reviewed sanitized derivative/,
    )
    assert.throws(
      () => validateVolumeRoot(evidenceRoot, environment),
      /overlaps protected source or application data/,
    )
  } finally {
    fs.rmSync(evidenceRoot, { recursive: true, force: true })
  }
})

test('default paired run measures both bindings and removes only its owned run directory', () => {
  const root = scratchRoot()
  try {
    const report = runVolumeHarness({ root, fixture })
    const initialCount = expectedEventCount()
    assert.equal(report.format, 'format-review-paired-volume/1')
    assert.match(
      report.runID,
      /^mechanician-volume-\d{8}T\d{6}Z-[0-9a-f]{8}-[0-9a-f-]{27}$/,
    )
    assert.equal(report.fixture.canonicalEventCount, initialCount)
    assert.equal(report.fixture.kind, 'deterministic-synthetic-sidecar')
    assert.equal(report.fixture.sanitizedCorpusOnly, false)
    assert.deepEqual(report.candidates.map((candidate) => candidate.kind), ['framed', 'chunked'])
    assert.equal(report.cleanup.status, 'removed')
    assert.equal(report.retainedRunDirectory, null)
    assert.deepEqual(fs.readdirSync(root), [], 'the explicit parent scratch root remains untouched')

    assert.equal(report.coordinationProbe.exclusiveCreateAndFileFsync.ok, true)
    assert.equal(report.coordinationProbe.sameDirectoryRename.ok, true)
    assert.equal(typeof report.coordinationProbe.directoryFsync.ok, 'boolean')
    assert.deepEqual(report.coordinationProbe.cleanupResidue, [])

    for (const candidate of report.candidates) {
      assert.deepEqual(candidate.errors, [], `${candidate.kind}: no phase errors`)
      assert.equal(candidate.initialEventCount, initialCount)
      assert.equal(candidate.expectedEventCount, initialCount + 1)
      assert.equal(candidate.boundaryDelta.resultBytes, 2048)
      assert.ok(candidate.boundaryDelta.logicalCommitBytes > 2048)
      assert.ok(candidate.initialBuildLogicalBytes > 0)
      for (const timing of Object.values(candidate.timingsMs)) {
        assert.equal(typeof timing, 'number')
        assert.ok(timing >= 0)
      }
      assert.notEqual(
        candidate.snapshots.beforeBoundary.sha256,
        candidate.snapshots.afterBoundary.sha256,
      )
      assert.equal(
        candidate.snapshots.afterBoundary.sha256,
        candidate.snapshots.afterRecovery.sha256,
      )
      assertAllocationSnapshot(candidate.snapshots.beforeBoundary)
      assertAllocationSnapshot(candidate.snapshots.afterBoundary)
      assert.equal(candidate.reads.fullEventCount, initialCount + 1)
      assert.equal(candidate.reads.newestToolUseId, 'volume-boundary-1')
      assert.equal(candidate.recovery.survivingEventCount, initialCount + 1)
      assert.equal(candidate.recovery.digestUnchanged, true)
      assert.deepEqual(candidate.residue.temporaryFiles, [])
      assert.deepEqual(candidate.residue.orphanChunks, [])
    }

    for (const observation of Object.values(report.externalObservation)) {
      assert.equal(observation.observed, false)
      assert.equal(observation.status, 'unproven')
    }
  } finally {
    fs.rmSync(root, { recursive: true, force: true })
  }
})

test('--retain leaves a paired artifact set and an inspectable report', () => {
  const root = scratchRoot()
  try {
    const report = runVolumeHarness({ root, fixture, retain: true })
    assert.equal(report.cleanup.status, 'retained')
    assert.equal(path.dirname(report.retainedRunDirectory), root)
    assert.equal(report.reportPath, path.join(report.retainedRunDirectory, 'volume-binding-report.json'))
    assert.ok(fs.existsSync(path.join(report.retainedRunDirectory, 'framed/record.mechframes')))
    assert.ok(fs.existsSync(path.join(report.retainedRunDirectory, 'chunked/record.package/head.json')))
    assert.ok(fs.existsSync(report.reportPath))
    const onDisk = JSON.parse(fs.readFileSync(report.reportPath, 'utf8'))
    assert.equal(onDisk.runID, report.runID)
    assert.equal(onDisk.cleanup.status, 'retained')
    assert.deepEqual(onDisk.candidates.map((candidate) => candidate.kind), ['framed', 'chunked'])
  } finally {
    fs.rmSync(root, { recursive: true, force: true })
  }
})
