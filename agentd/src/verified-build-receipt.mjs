import fs from 'node:fs'
import path from 'node:path'
import { execFile } from 'node:child_process'
import { createHash, randomUUID } from 'node:crypto'
import { promisify } from 'node:util'

const execFileP = promisify(execFile)

export const VERIFIED_BUILD_RECEIPT_SCHEMA = 'mechanician.verified-build-observation.v1'
export const VERIFIED_BUILD_CORRELATION_FIELD = 'verifiedKnowledgeCorrelationID'

const BUILD_SPECS = Object.freeze({
  'swift-build': Object.freeze({ executable: 'swift', args: Object.freeze(['build']) }),
  'swift-test': Object.freeze({ executable: 'swift', args: Object.freeze(['test']) }),
  'xcode-build': Object.freeze({ executable: 'xcodebuild', args: Object.freeze(['build']) }),
  'xcode-test': Object.freeze({ executable: 'xcodebuild', args: Object.freeze(['test']) }),
})

const RECEIPT_COMMANDS = new Set(['swift-build', 'xcode-build'])
const MAX_COMMAND_BYTES = 8 * 1024 * 1024
const MAX_UNTRACKED_FILES = 10_000
const MAX_UNTRACKED_BYTES = 128 * 1024 * 1024

function sha256(value) {
  return createHash('sha256').update(value).digest('hex')
}

function canonicalJSON(value) {
  if (Array.isArray(value)) return `[${value.map(canonicalJSON).join(',')}]`
  if (value && typeof value === 'object') {
    return `{${Object.keys(value).sort().map((key) => (
      `${JSON.stringify(key)}:${canonicalJSON(value[key])}`
    )).join(',')}}`
  }
  return JSON.stringify(value)
}

function commandOptions(root, maxBuffer = MAX_COMMAND_BYTES) {
  return {
    cwd: root,
    encoding: null,
    maxBuffer,
    env: process.env,
  }
}

async function commandBytes(executable, args, root, dependencies) {
  const run = dependencies?.execFile || execFileP
  const result = await run(executable, args, commandOptions(root))
  return Buffer.concat([
    Buffer.isBuffer(result.stdout) ? result.stdout : Buffer.from(result.stdout || ''),
    Buffer.isBuffer(result.stderr) ? result.stderr : Buffer.from(result.stderr || ''),
  ])
}

async function resolvedExecutable(spec, root, dependencies) {
  const output = await commandBytes('/usr/bin/which', [spec.executable], root, dependencies)
  const candidate = output.toString('utf8').trim()
  if (!candidate || !path.isAbsolute(candidate)) throw new Error('build executable is unavailable')
  const realpath = dependencies?.realpath || fs.promises.realpath
  return await realpath(candidate)
}

async function toolchainSHA256(spec, root, dependencies) {
  const executable = await resolvedExecutable(spec, root, dependencies)
  const versionArgs = spec.executable === 'xcodebuild' ? ['-version'] : ['--version']
  const version = await commandBytes(executable, versionArgs, root, dependencies)
  const material = Buffer.concat([
    Buffer.from('mechanician-build-toolchain-v1\0'),
    Buffer.from(executable), Buffer.from('\0'), version,
  ])
  return sha256(material)
}

async function untrackedMaterial(root, dependencies) {
  const names = await commandBytes(
    'git', ['ls-files', '--others', '--exclude-standard', '-z'], root, dependencies)
  const relativePaths = names.toString('utf8').split('\0').filter(Boolean).sort()
  if (relativePaths.length > MAX_UNTRACKED_FILES) {
    throw new Error('too many untracked files for an exact build receipt')
  }
  const readFile = dependencies?.readFile || fs.promises.readFile
  const lstat = dependencies?.lstat || fs.promises.lstat
  const readlink = dependencies?.readlink || fs.promises.readlink
  const hash = createHash('sha256')
  hash.update('mechanician-untracked-tree-v1\0')
  let total = 0
  for (const relative of relativePaths) {
    if (path.isAbsolute(relative) || relative.split(path.sep).includes('..')) {
      throw new Error('git returned an unsafe untracked path')
    }
    const absolute = path.join(root, relative)
    const stat = await lstat(absolute)
    let kind
    let bytes
    if (stat.isSymbolicLink()) {
      kind = 'symlink'
      bytes = Buffer.from(await readlink(absolute))
    } else if (stat.isFile()) {
      kind = 'file'
      bytes = await readFile(absolute)
    } else {
      throw new Error('unsupported untracked filesystem entry')
    }
    total += bytes.length
    if (total > MAX_UNTRACKED_BYTES) {
      throw new Error('untracked files exceed the exact build receipt bound')
    }
    hash.update(kind); hash.update('\0'); hash.update(relative); hash.update('\0')
    hash.update(String(stat.mode & 0o7777)); hash.update('\0')
    hash.update(sha256(bytes)); hash.update('\0')
  }
  return hash.digest('hex')
}

async function dirtyTreeSHA256(root, dependencies) {
  const [status, diff, untracked] = await Promise.all([
    commandBytes(
      'git', ['status', '--porcelain=v2', '-z', '--untracked-files=all',
        '--ignore-submodules=none'], root, dependencies),
    commandBytes(
      'git', ['diff', '--binary', '--no-ext-diff', 'HEAD', '--'], root, dependencies),
    untrackedMaterial(root, dependencies),
  ])
  return sha256(Buffer.concat([
    Buffer.from('mechanician-dirty-tree-v1\0'),
    status, Buffer.from('\0'), diff, Buffer.from('\0'), Buffer.from(untracked),
  ]))
}

function lowercaseCommit(value) {
  const commit = value.toString('utf8').trim().toLowerCase()
  if (!/^[0-9a-f]{40,64}$/.test(commit)) throw new Error('workspace has no exact HEAD commit')
  return commit
}

/// Capture only a top-level Git workspace. A nested folder cannot be promoted by borrowing the
/// parent repository's state, and a non-Git folder has no stable source coordinate for this recipe.
export async function captureVerifiedBuildWorkspaceSnapshot(rootValue, command, dependencies = {}) {
  const spec = verifiedBuildSpec(command)
  if (!spec || !RECEIPT_COMMANDS.has(command)) return null
  const realpath = dependencies.realpath || fs.promises.realpath
  const root = await realpath(rootValue)
  const topLevel = (await commandBytes('git', ['rev-parse', '--show-toplevel'], root, dependencies))
    .toString('utf8').trim()
  if (!topLevel || await realpath(topLevel) !== root) return null
  const [headBytes, dirty, toolchain] = await Promise.all([
    commandBytes('git', ['rev-parse', '--verify', 'HEAD'], root, dependencies),
    dirtyTreeSHA256(root, dependencies),
    toolchainSHA256(spec, root, dependencies),
  ])
  return Object.freeze({
    rootSHA256: sha256(Buffer.from(root)),
    headCommit: lowercaseCommit(headBytes),
    dirtyTreeSHA256: dirty,
    toolchainSHA256: toolchain,
  })
}

export function verifiedBuildSpec(command) {
  return BUILD_SPECS[command] || null
}

export function verifiedBuildInvocationSHA256(command, snapshot) {
  const spec = verifiedBuildSpec(command)
  if (!spec || !snapshot) return null
  return sha256(Buffer.from(canonicalJSON({
    formatVersion: 1,
    command,
    executable: spec.executable,
    arguments: [...spec.args],
    rootSHA256: snapshot.rootSHA256,
    toolchainSHA256: snapshot.toolchainSHA256,
  })))
}

export function verifiedBuildDiagnosticsSHA256(diagnostics) {
  const closed = Array.isArray(diagnostics) ? diagnostics.map((diagnostic) => ({
    file: String(diagnostic?.file || ''),
    line: Number.isInteger(diagnostic?.line) ? diagnostic.line : 0,
    col: Number.isInteger(diagnostic?.col) ? diagnostic.col : 0,
    severity: String(diagnostic?.severity || ''),
    message: String(diagnostic?.message || ''),
  })) : []
  return sha256(Buffer.from(canonicalJSON({ formatVersion: 1, diagnostics: closed })))
}

function snapshotsEqual(left, right) {
  return left && right
    && left.rootSHA256 === right.rootSHA256
    && left.headCommit === right.headCommit
    && left.dirtyTreeSHA256 === right.dirtyTreeSHA256
    && left.toolchainSHA256 === right.toolchainSHA256
}

/// Build/test stdout and diagnostics never enter this payload. Diagnostics influence only a
/// one-way digest and the closed zero-error admission fact.
export function verifiedBuildObservation({
  command,
  code,
  diagnostics,
  before,
  after,
  observedAt = new Date(),
  correlationID = randomUUID(),
}) {
  if (!RECEIPT_COMMANDS.has(command) || code !== 0 || !snapshotsEqual(before, after)) return null
  const compilerErrorCount = Array.isArray(diagnostics)
    ? diagnostics.filter((value) => value?.severity === 'error').length
    : 0
  if (compilerErrorCount !== 0 || !(observedAt instanceof Date)
      || !Number.isFinite(observedAt.getTime())) return null
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i
    .test(correlationID)) return null
  const invocationSHA256 = verifiedBuildInvocationSHA256(command, before)
  if (!invocationSHA256) return null
  return Object.freeze({
    schema: VERIFIED_BUILD_RECEIPT_SCHEMA,
    correlationID: correlationID.toLowerCase(),
    command,
    observedAt: observedAt.toISOString(),
    lifecycle: 'succeeded',
    effect: 'verification_execution',
    exitCode: 0,
    compilerErrorCount: 0,
    invocationSHA256,
    diagnosticsSHA256: verifiedBuildDiagnosticsSHA256(diagnostics),
    workspaceBefore: before,
    workspaceAfter: after,
  })
}

export function buildToolResultCorrelation(observation) {
  return observation ? { [VERIFIED_BUILD_CORRELATION_FIELD]: observation.correlationID } : {}
}
