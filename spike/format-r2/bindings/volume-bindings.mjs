// Bounded paired-volume evidence harness for the format review.
//
// This tool deliberately exercises only the two incremental binding candidates. It requires an
// explicit scratch root and a reviewed fixture, creates exactly one owned run directory, and
// removes that directory by default. An explicitly configured external evidence checkout can
// supply reviewed corpus fixtures for manual runs; the repository-owned deterministic fixture
// keeps this harness self-contained in CI. Pass --retain when an external File Provider,
// network-volume observer, or second device needs time to inspect the artifacts.
//
// This process can measure local application writes and local filesystem allocation. It cannot
// infer upload bytes, synchronization convergence, device-A-to-device-B fidelity, or concurrent
// conflict behavior. Those facts stay explicitly unproven until externally observed.
import crypto from 'node:crypto'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { performance } from 'node:perf_hooks'
import { fileURLToPath } from 'node:url'
import { canonicalFromSidecar } from '../canonical-from-sidecar.mjs'
import {
  optionalFormatEvidenceRepository,
  resolveFormatEvidenceRepository,
} from '../external-evidence-repository.mjs'
import { createFramed } from './binding-framed.mjs'
import { createChunked } from './binding-chunked.mjs'

const MODULE_DIR = path.dirname(fileURLToPath(import.meta.url))
const REPOSITORY_ROOT = path.resolve(MODULE_DIR, '../../..')
export const DETERMINISTIC_VOLUME_FIXTURE = path.join(
  REPOSITORY_ROOT,
  'spike/format-r2/test/fixtures/volume-binding-sidecar.json',
)

const REVIEWED_FIXTURES = new Set([
  'activity-heavy.json',
  'large-compaction-subagents.json',
  'median-plain.json',
  'subagent-workflow-heavy.json',
])
const RUN_PREFIX = 'mechanician-volume-'
const REPORT_NAME = 'volume-binding-report.json'
const ERROR_MESSAGE_LIMIT = 500
const BOUNDARY_RESULT_BYTES = 2 * 1024

const BOUNDARY_EVENT = Object.freeze({
  kind: 'tool_result',
  agentId: 'root',
  toolUseId: 'volume-boundary-1',
  result: 'x'.repeat(BOUNDARY_RESULT_BYTES),
  isError: false,
  observedAt: '1970-01-01T00:00:00.000Z',
  timeProvenance: 'volume-harness',
})

function fail(message, code = 'HARNESS_VALIDATION') {
  const error = new Error(message)
  error.code = code
  throw error
}

function resolvedRealPath(candidate, label) {
  const resolved = path.resolve(candidate)
  let real
  try {
    real = fs.realpathSync(resolved)
  } catch (error) {
    fail(`${label} does not resolve to an existing path: ${resolved}`, error.code ?? 'ENOENT')
  }
  if (real !== resolved) {
    fail(`${label} must not contain symlinks: ${resolved}`, 'HARNESS_SYMLINK')
  }
  return resolved
}

function sameOrAncestor(ancestor, candidate) {
  const relative = path.relative(ancestor, candidate)
  return relative === '' || (!relative.startsWith('..') && !path.isAbsolute(relative))
}

function pathsOverlap(left, right) {
  return sameOrAncestor(left, right) || sameOrAncestor(right, left)
}

function existingRealPath(candidate) {
  try {
    return fs.realpathSync(candidate)
  } catch {
    return path.resolve(candidate)
  }
}

export function validateVolumeRoot(candidate, environment = process.env) {
  if (typeof candidate !== 'string' || candidate.trim() === '') {
    fail('--root requires an explicit existing scratch directory')
  }
  const root = resolvedRealPath(candidate, 'Volume root')
  const stat = fs.lstatSync(root)
  if (!stat.isDirectory() || stat.isSymbolicLink()) {
    fail(`Volume root must be a real directory: ${root}`)
  }

  const home = existingRealPath(os.homedir())
  const cloudDocs = path.join(home, 'Library/Mobile Documents/com~apple~CloudDocs')
  const exactBroadRoots = new Set([
    '/',
    '/Applications',
    '/Library',
    '/Network',
    '/System',
    '/System/Volumes',
    '/System/Volumes/Data',
    '/Users',
    '/Users/Shared',
    '/Volumes',
    '/bin',
    '/dev',
    '/etc',
    '/opt',
    '/private',
    '/sbin',
    '/tmp',
    '/private/tmp',
    '/var',
    '/private/var',
    '/usr',
    home,
    path.join(home, 'Desktop'),
    path.join(home, 'Documents'),
    path.join(home, 'Downloads'),
    path.join(home, 'Library'),
    path.join(home, 'Library/Application Support'),
    path.join(home, 'Library/Mobile Documents'),
    existingRealPath(cloudDocs),
  ].map((entry) => path.resolve(entry)))
  if (exactBroadRoots.has(root)) {
    fail(`Refusing broad or user-data root; pass a dedicated child scratch directory: ${root}`)
  }

  const volumesRoot = path.resolve('/Volumes')
  if (path.dirname(root) === volumesRoot) {
    fail(`Refusing a mount root; create a dedicated child scratch directory inside it: ${root}`)
  }

  const externalEvidence = optionalFormatEvidenceRepository(environment)
  const protectedPaths = [
    existingRealPath(REPOSITORY_ROOT),
    existingRealPath(path.join(home, 'Library/Application Support/Mechanician')),
  ]
  if (externalEvidence) {
    protectedPaths.push(
      externalEvidence.repositoryRoot,
      externalEvidence.evidenceDirectory,
      path.join(externalEvidence.evidenceDirectory, 'corpus'),
    )
  }
  for (const protectedPath of protectedPaths) {
    if (pathsOverlap(root, protectedPath)) {
      fail(`Volume root overlaps protected source or application data: ${root}`)
    }
  }
  try {
    fs.accessSync(root, fs.constants.R_OK | fs.constants.W_OK | fs.constants.X_OK)
  } catch (error) {
    fail(`Volume root is not readable and writable: ${root}`, error.code ?? 'EACCES')
  }
  return root
}

export function validateSanitizedFixture(candidate, environment = process.env) {
  if (typeof candidate !== 'string' || candidate.trim() === '') {
    fail('--fixture requires one reviewed JSON fixture')
  }
  const fixture = resolvedRealPath(candidate, 'Fixture')
  const stat = fs.lstatSync(fixture)
  if (!stat.isFile() || stat.isSymbolicLink()) {
    fail(`Fixture must be a regular file: ${fixture}`)
  }
  const isDeterministicRepositoryFixture = fixture === resolvedRealPath(
    DETERMINISTIC_VOLUME_FIXTURE,
    'Deterministic volume fixture',
  )
  if (isDeterministicRepositoryFixture) return fixture

  const externalEvidence = resolveFormatEvidenceRepository(environment)
  const corpusRoot = path.join(externalEvidence.evidenceDirectory, 'corpus')
  const isReviewedSanitizedDerivative = path.dirname(fixture) === corpusRoot
    && REVIEWED_FIXTURES.has(path.basename(fixture))
  if (!isReviewedSanitizedDerivative) {
    fail('Fixture must be a reviewed sanitized derivative or the deterministic repository fixture')
  }
  return fixture
}

function fixtureKind(fixture) {
  return fixture === path.resolve(DETERMINISTIC_VOLUME_FIXTURE)
    ? 'deterministic-synthetic-sidecar'
    : 'reviewed-sanitized-derivative'
}

export function parseArguments(argv) {
  const parsed = { root: null, fixture: null, retain: false }
  const seen = new Set()
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index]
    if (argument === '--retain') {
      if (seen.has(argument)) fail('Duplicate argument: --retain')
      seen.add(argument)
      parsed.retain = true
      continue
    }
    if (argument !== '--root' && argument !== '--fixture') {
      fail(`Unknown argument: ${argument}`)
    }
    if (seen.has(argument)) fail(`Duplicate argument: ${argument}`)
    seen.add(argument)
    const value = argv[index + 1]
    if (!value || value.startsWith('--')) fail(`${argument} requires a value`)
    index += 1
    parsed[argument.slice(2)] = value
  }
  if (!parsed.root) fail('Missing required --root <dedicated-scratch-directory>')
  if (!parsed.fixture) fail('Missing required --fixture <reviewed-sanitized-json>')
  return parsed
}

export function makeRunID(now = new Date(), uuid = crypto.randomUUID()) {
  const timestamp = now.toISOString().replace(/[-:]/g, '').replace(/\.\d{3}Z$/, 'Z')
  return `${RUN_PREFIX}${timestamp}-${uuid}`
}

function serializeNumber(value) {
  if (typeof value === 'bigint') return value.toString()
  return Number.isFinite(value) ? value : null
}

function filesystemFacts(root) {
  const stat = fs.statSync(root)
  let filesystem = null
  try {
    const details = fs.statfsSync(root)
    filesystem = {
      type: serializeNumber(details.type),
      blockSize: serializeNumber(details.bsize),
      totalBlocks: serializeNumber(details.blocks),
      availableBlocks: serializeNumber(details.bavail),
    }
  } catch (error) {
    filesystem = { error: structuredError(error, 'statfs') }
  }
  return { device: serializeNumber(stat.dev), filesystem }
}

function structuredError(error, phase) {
  const rawMessage = error instanceof Error ? error.message : String(error)
  return {
    phase,
    category: error?.code && String(error.code).startsWith('E') ? 'filesystem' : 'harness',
    code: error?.code ?? null,
    message: rawMessage.slice(0, ERROR_MESSAGE_LIMIT),
  }
}

function measure(operation) {
  const started = performance.now()
  const value = operation()
  return { milliseconds: performance.now() - started, value }
}

function hashFile(hash, filePath) {
  const fd = fs.openSync(filePath, 'r')
  const buffer = Buffer.allocUnsafe(1024 * 1024)
  try {
    for (;;) {
      const count = fs.readSync(fd, buffer, 0, buffer.length, null)
      if (count === 0) break
      hash.update(buffer.subarray(0, count))
    }
  } finally {
    fs.closeSync(fd)
  }
}

function listTree(rootPath) {
  const rootStat = fs.lstatSync(rootPath)
  if (rootStat.isSymbolicLink()) fail(`Artifact tree contains a symlink: ${rootPath}`)
  const entries = []
  const visit = (absolute, relative) => {
    const stat = fs.lstatSync(absolute)
    if (stat.isSymbolicLink()) fail(`Artifact tree contains a symlink: ${absolute}`)
    if (stat.isDirectory()) {
      entries.push({ type: 'directory', absolute, relative, stat })
      for (const name of fs.readdirSync(absolute).sort()) {
        visit(path.join(absolute, name), relative === '.' ? name : path.join(relative, name))
      }
      return
    }
    if (stat.isFile()) {
      entries.push({ type: 'file', absolute, relative, stat })
      return
    }
    fail(`Artifact tree contains a non-file, non-directory entry: ${absolute}`)
  }
  visit(rootPath, '.')
  return entries
}

export function snapshotArtifact(artifactPath) {
  const entries = listTree(artifactPath)
  const hash = crypto.createHash('sha256')
  let fileCount = 0
  let directoryCount = 0
  let logicalBytes = 0
  let allocatedBytes = 0
  let allocatedBytesAvailable = true
  hash.update('mechanician-volume-artifact/1\n')
  for (const entry of entries) {
    hash.update(`${entry.type}\0${entry.relative}\0${entry.stat.size}\n`)
    if (entry.type === 'directory') {
      directoryCount += 1
      continue
    }
    fileCount += 1
    logicalBytes += entry.stat.size
    if (typeof entry.stat.blocks === 'number' && Number.isFinite(entry.stat.blocks)) {
      allocatedBytes += entry.stat.blocks * 512
    } else {
      allocatedBytesAvailable = false
    }
    hashFile(hash, entry.absolute)
    hash.update('\n')
  }
  return {
    sha256: hash.digest('hex'),
    fileCount,
    directoryCount,
    logicalBytes,
    allocatedBytes: allocatedBytesAvailable ? allocatedBytes : null,
    allocatedBytesAvailable,
  }
}

function listRelativeFiles(root) {
  if (!fs.existsSync(root)) return []
  return listTree(root)
    .filter((entry) => entry.type === 'file')
    .map((entry) => entry.relative)
    .sort()
}

function collectResidue(kind, containerPath, artifactPath) {
  const files = listRelativeFiles(containerPath)
  const temporaryFiles = files.filter((entry) => entry.endsWith('.tmp'))
  const residue = { temporaryFiles, orphanChunks: [] }
  if (kind !== 'chunked' || !fs.existsSync(artifactPath)) return residue

  const chunksDirectory = path.join(artifactPath, 'chunks')
  const headPath = path.join(artifactPath, 'head.json')
  if (!fs.existsSync(chunksDirectory) || !fs.existsSync(headPath)) return residue
  const referenced = new Set(
    JSON.parse(fs.readFileSync(headPath, 'utf8')).chunks.map((chunk) => chunk.name),
  )
  residue.orphanChunks = fs.readdirSync(chunksDirectory)
    .filter((name) => !referenced.has(name))
    .sort()
  return residue
}

function probeResult(ok, error = null) {
  return { ok, error }
}

function coordinationProbe(runDirectory) {
  const probeDirectory = path.join(runDirectory, 'coordination-probe')
  const temporary = path.join(probeDirectory, 'probe.tmp')
  const published = path.join(probeDirectory, 'probe.published')
  const result = {
    exclusiveCreateAndFileFsync: probeResult(false),
    sameDirectoryRename: probeResult(false),
    directoryFsync: probeResult(false),
    cleanupResidue: [],
  }
  let fileDescriptor = null
  let directoryDescriptor = null
  try {
    fs.mkdirSync(probeDirectory, { mode: 0o700 })
    try {
      fileDescriptor = fs.openSync(temporary, 'wx', 0o600)
      fs.writeSync(fileDescriptor, Buffer.from('mechanician-volume-probe/1'))
      fs.fsyncSync(fileDescriptor)
      result.exclusiveCreateAndFileFsync = probeResult(true)
    } catch (error) {
      result.exclusiveCreateAndFileFsync = probeResult(false, structuredError(error, 'file-fsync'))
    } finally {
      if (fileDescriptor !== null) {
        try { fs.closeSync(fileDescriptor) } catch { /* the recorded operation is already enough */ }
        fileDescriptor = null
      }
    }
    try {
      fs.renameSync(temporary, published)
      result.sameDirectoryRename = probeResult(true)
    } catch (error) {
      result.sameDirectoryRename = probeResult(false, structuredError(error, 'rename'))
    }
    try {
      directoryDescriptor = fs.openSync(probeDirectory, 'r')
      fs.fsyncSync(directoryDescriptor)
      result.directoryFsync = probeResult(true)
    } catch (error) {
      result.directoryFsync = probeResult(false, structuredError(error, 'directory-fsync'))
    } finally {
      if (directoryDescriptor !== null) {
        try { fs.closeSync(directoryDescriptor) } catch { /* recorded above if material */ }
        directoryDescriptor = null
      }
    }
  } catch (error) {
    const setupError = structuredError(error, 'coordination-probe-setup')
    if (!result.exclusiveCreateAndFileFsync.error) {
      result.exclusiveCreateAndFileFsync = probeResult(false, setupError)
    }
  } finally {
    if (fs.existsSync(probeDirectory)) {
      try {
        result.cleanupResidue = listRelativeFiles(probeDirectory)
        fs.rmSync(probeDirectory, { recursive: true, force: true })
        result.cleanupResidue = []
      } catch (error) {
        result.cleanupResidue = [{ error: structuredError(error, 'coordination-probe-cleanup') }]
      }
    }
  }
  return result
}

function candidateSkeleton(kind, relativeArtifact, initialEventCount) {
  return {
    kind,
    relativeArtifact,
    initialEventCount,
    expectedEventCount: initialEventCount + 1,
    boundaryDelta: {
      toolUseId: BOUNDARY_EVENT.toolUseId,
      resultBytes: BOUNDARY_RESULT_BYTES,
      logicalCommitBytes: null,
    },
    timingsMs: {
      initialBuild: null,
      boundaryCommit: null,
      openTailRead: null,
      fullDecodeRead: null,
      cleanRecovery: null,
    },
    initialBuildLogicalBytes: null,
    snapshots: { beforeBoundary: null, afterBoundary: null, afterRecovery: null },
    reads: { tailEventCount: null, fullEventCount: null, newestToolUseId: null },
    recovery: { survivingEventCount: null, digestUnchanged: null },
    residue: { temporaryFiles: [], orphanChunks: [] },
    errors: [],
  }
}

function verify(condition, message) {
  if (!condition) fail(message, 'HARNESS_VERIFICATION')
}

function exerciseCandidate({ kind, runDirectory, initialEvents }) {
  const containerPath = path.join(runDirectory, kind)
  fs.mkdirSync(containerPath, { mode: 0o700 })
  const artifactPath = kind === 'framed'
    ? path.join(containerPath, 'record.mechframes')
    : path.join(containerPath, 'record.package')
  const relativeArtifact = path.relative(runDirectory, artifactPath)
  const result = candidateSkeleton(kind, relativeArtifact, initialEvents.length)
  const binding = kind === 'framed' ? createFramed(artifactPath) : createChunked(artifactPath)
  let phase = 'initial-build'
  try {
    const initialBuild = measure(() => binding.build(initialEvents))
    result.timingsMs.initialBuild = initialBuild.milliseconds
    result.initialBuildLogicalBytes = initialBuild.value

    phase = 'snapshot-before-boundary'
    result.snapshots.beforeBoundary = snapshotArtifact(artifactPath)

    phase = 'boundary-commit'
    const boundaryCommit = measure(() => binding.commitBoundary(BOUNDARY_EVENT))
    result.timingsMs.boundaryCommit = boundaryCommit.milliseconds
    result.boundaryDelta.logicalCommitBytes = boundaryCommit.value

    phase = 'snapshot-after-boundary'
    result.snapshots.afterBoundary = snapshotArtifact(artifactPath)
    verify(
      result.snapshots.beforeBoundary.sha256 !== result.snapshots.afterBoundary.sha256,
      `${kind}: boundary commit did not change the artifact digest`,
    )

    phase = 'tail-read'
    const tailRead = measure(() => binding.openTail(50))
    result.timingsMs.openTailRead = tailRead.milliseconds
    result.reads.tailEventCount = tailRead.value.length
    result.reads.newestToolUseId = tailRead.value.at(-1)?.toolUseId ?? null
    verify(
      result.reads.newestToolUseId === BOUNDARY_EVENT.toolUseId,
      `${kind}: tail read did not observe the boundary event`,
    )

    phase = 'full-decode-read'
    const fullDecode = measure(() => binding.fullDecode())
    result.timingsMs.fullDecodeRead = fullDecode.milliseconds
    result.reads.fullEventCount = fullDecode.value.length
    verify(
      fullDecode.value.length === result.expectedEventCount,
      `${kind}: full decode event count differs from the expected count`,
    )

    phase = 'clean-recovery'
    const recovery = measure(() => binding.recover())
    result.timingsMs.cleanRecovery = recovery.milliseconds
    result.recovery.survivingEventCount = recovery.value
    verify(
      recovery.value === result.expectedEventCount,
      `${kind}: clean recovery event count differs from the expected count`,
    )

    phase = 'snapshot-after-recovery'
    result.snapshots.afterRecovery = snapshotArtifact(artifactPath)
    result.recovery.digestUnchanged =
      result.snapshots.afterRecovery.sha256 === result.snapshots.afterBoundary.sha256
    verify(result.recovery.digestUnchanged, `${kind}: clean recovery mutated the artifact`)
  } catch (error) {
    result.errors.push(structuredError(error, phase))
  } finally {
    try {
      result.residue = collectResidue(kind, containerPath, artifactPath)
    } catch (error) {
      result.errors.push(structuredError(error, 'residue-inspection'))
    }
  }
  return result
}

function assertOwnedRunDirectory(root, runDirectory, runID, inspectTree = true) {
  verify(path.dirname(runDirectory) === root, 'Owned run directory escaped the validated root')
  verify(path.basename(runDirectory) === runID, 'Owned run directory does not match its run ID')
  verify(runID.startsWith(RUN_PREFIX), 'Owned run directory has an invalid prefix')
  const stat = fs.lstatSync(runDirectory)
  verify(stat.isDirectory() && !stat.isSymbolicLink(), 'Owned run path is not a real directory')
  verify(fs.realpathSync(runDirectory) === runDirectory, 'Owned run directory contains a symlink path')
  if (inspectTree) listTree(runDirectory)
}

function removeOwnedRunDirectory(root, runDirectory, runID) {
  if (!fs.existsSync(runDirectory)) return
  assertOwnedRunDirectory(root, runDirectory, runID)
  fs.rmSync(runDirectory, { recursive: true, force: false })
}

function writeRetainedReport(runDirectory, report) {
  const reportPath = path.join(runDirectory, REPORT_NAME)
  const temporaryPath = `${reportPath}.tmp`
  const payload = Buffer.from(`${JSON.stringify(report, null, 2)}\n`)
  const descriptor = fs.openSync(temporaryPath, 'wx', 0o600)
  try {
    fs.writeSync(descriptor, payload)
    fs.fsyncSync(descriptor)
  } finally {
    fs.closeSync(descriptor)
  }
  fs.renameSync(temporaryPath, reportPath)
  return reportPath
}

const unproven = (why) => ({ observed: false, status: 'unproven', reason: why })

export function runVolumeHarness({ root: rootCandidate, fixture: fixtureCandidate, retain = false }) {
  const root = validateVolumeRoot(rootCandidate)
  const fixture = validateSanitizedFixture(fixtureCandidate)
  const source = JSON.parse(fs.readFileSync(fixture, 'utf8'))
  const canonical = canonicalFromSidecar(source)
  verify(Array.isArray(canonical.events), 'Sanitized fixture did not produce canonical events')

  const runID = makeRunID()
  const runDirectory = path.join(root, runID)
  fs.mkdirSync(runDirectory, { mode: 0o700 })
  assertOwnedRunDirectory(root, runDirectory, runID, false)

  let report = null
  try {
    report = {
      format: 'format-review-paired-volume/1',
      generatedAt: new Date().toISOString(),
      runID,
      root,
      retainedRunDirectory: retain ? runDirectory : null,
      fixture: {
        name: path.basename(fixture),
        sha256: crypto.createHash('sha256').update(fs.readFileSync(fixture)).digest('hex'),
        canonicalEventCount: canonical.events.length,
        kind: fixtureKind(fixture),
        sanitizedCorpusOnly: fixtureKind(fixture) === 'reviewed-sanitized-derivative',
      },
      filesystem: filesystemFacts(root),
      coordinationProbe: coordinationProbe(runDirectory),
      candidates: [
        exerciseCandidate({ kind: 'framed', runDirectory, initialEvents: canonical.events }),
        exerciseCandidate({ kind: 'chunked', runDirectory, initialEvents: canonical.events }),
      ],
      measurementMeaning: {
        logicalCommitBytes: 'Bytes returned by the prototype binding for the application write.',
        artifactLogicalBytes: 'Sum of regular-file sizes from local stat data.',
        allocatedBytes: 'Local stat.blocks multiplied by 512; not transfer or upload bytes.',
      },
      externalObservation: {
        actualTransferBytes: unproven('Requires File Provider or network transport observation.'),
        syncConvergence: unproven('Requires observing the provider or server reach a stable state.'),
        deviceAToBRoundTrip: unproven('Requires a second device to open and verify both artifacts.'),
        concurrentConflictBehavior: unproven('Requires controlled concurrent writers on two devices.'),
      },
      caveats: [
        'The chunked candidate is an ordinary directory in this spike; Finder package behavior is unproven.',
        'A retained run preserves paired artifacts for external observation; this process does not infer synchronization from local success.',
      ],
      cleanup: { requested: retain ? 'retain' : 'remove', status: 'pending', error: null },
    }

    if (retain) {
      report.cleanup.status = 'retained'
      report.reportPath = path.join(runDirectory, REPORT_NAME)
      writeRetainedReport(runDirectory, report)
    }
  } finally {
    if (!retain) {
      try {
        removeOwnedRunDirectory(root, runDirectory, runID)
        if (report) report.cleanup.status = 'removed'
      } catch (error) {
        if (report) {
          report.cleanup.status = 'failed'
          report.cleanup.error = structuredError(error, 'cleanup')
          report.retainedRunDirectory = fs.existsSync(runDirectory) ? runDirectory : null
        } else {
          throw error
        }
      }
    }
  }
  return report
}

function isDirectInvocation() {
  if (!process.argv[1]) return false
  return fileURLToPath(import.meta.url) === path.resolve(process.argv[1])
}

if (isDirectInvocation()) {
  try {
    const options = parseArguments(process.argv.slice(2))
    const report = runVolumeHarness(options)
    process.stdout.write(`${JSON.stringify(report, null, 2)}\n`)
    if (report.candidates.some((candidate) => candidate.errors.length > 0)) process.exitCode = 2
    if (report.cleanup.status === 'failed') process.exitCode = 3
  } catch (error) {
    const output = structuredError(error, 'command-line')
    process.stderr.write(`${JSON.stringify(output, null, 2)}\n`)
    process.exitCode = 1
  }
}
