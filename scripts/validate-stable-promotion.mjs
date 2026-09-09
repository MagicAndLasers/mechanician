#!/usr/bin/env node

import crypto from 'node:crypto'
import fs from 'node:fs'

const FORMAT = 'ai.mechanician.stable-promotion-attestation.v1'
const RECORD_FORMAT = 'ai.mechanician.stable-promotion-authorization.v1'
const MINIMUM_SOAK_MILLISECONDS = 24 * 60 * 60 * 1000
const REQUIRED_CHECKS = [
  'launch',
  'update',
  'storage',
  'claude',
  'codex',
  'backgroundProcesses',
  'crashFree',
]

function fail(message) {
  process.stderr.write(`!! ${message}\n`)
  process.exit(1)
}

function usage() {
  process.stderr.write(
    'usage: validate-stable-promotion.mjs --attestation FILE --version X.Y.Z --build N ' +
    '--zip-sha SHA256 --dmg-sha SHA256 --provenance-sha SHA256 --source-commit SHA ' +
    '--released-at TIMESTAMP [--urgent-reason TEXT]\n',
  )
  process.exit(64)
}

function parseArguments(arguments_) {
  const values = new Map()
  const allowed = new Set([
    '--attestation',
    '--version',
    '--build',
    '--zip-sha',
    '--dmg-sha',
    '--provenance-sha',
    '--source-commit',
    '--released-at',
    '--urgent-reason',
  ])
  for (let index = 0; index < arguments_.length; index += 2) {
    const key = arguments_[index]
    const value = arguments_[index + 1]
    if (!allowed.has(key) || value === undefined || values.has(key)) usage()
    values.set(key, value)
  }
  for (const required of [
    '--attestation',
    '--version',
    '--build',
    '--zip-sha',
    '--dmg-sha',
    '--provenance-sha',
    '--source-commit',
    '--released-at',
  ]) {
    if (!values.has(required)) usage()
  }
  return values
}

function requireObject(value, label) {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) {
    fail(`${label} must be an object`)
  }
  return value
}

function requireExactKeys(value, expected, label) {
  const actual = Object.keys(requireObject(value, label)).sort()
  const wanted = [...expected].sort()
  if (actual.length !== wanted.length || actual.some((key, index) => key !== wanted[index])) {
    fail(`${label} must contain exactly: ${wanted.join(', ')}`)
  }
}

function requireString(value, label) {
  if (typeof value !== 'string' || value.trim() !== value || value.length === 0) {
    fail(`${label} must be a non-empty trimmed string`)
  }
  if (/[^\x20-\x7e]/u.test(value)) fail(`${label} must contain printable ASCII only`)
  return value
}

function requireDigest(value, label) {
  const digest = requireString(value, label)
  if (!/^[0-9a-f]{64}$/u.test(digest)) fail(`${label} must be a lowercase SHA-256 digest`)
  return digest
}

function requireCommit(value, label) {
  const commit = requireString(value, label)
  if (!/^[0-9a-f]{40}$/u.test(commit)) fail(`${label} must be a full lowercase Git commit ID`)
  return commit
}

function requireBuild(value, label) {
  if (!Number.isSafeInteger(value) || value <= 0) fail(`${label} must be a positive integer`)
  return value
}

function requireVersion(value, label) {
  const version = requireString(value, label)
  if (!/^\d+\.\d+\.\d+$/u.test(version)) fail(`${label} must be a numeric semantic version`)
  return version
}

function requireTimestamp(value, label, { utcOnly = true } = {}) {
  const timestamp = requireString(value, label)
  const zone = utcOnly ? 'Z' : '(?:Z|[+-]\\d{2}:\\d{2})'
  if (!new RegExp(`^\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}(?:\\.\\d{3})?${zone}$`, 'u').test(timestamp)) {
    fail(`${label} must be an RFC 3339 timestamp${utcOnly ? ' in UTC' : ''}`)
  }
  const milliseconds = Date.parse(timestamp)
  if (!Number.isFinite(milliseconds)) fail(`${label} is not a valid timestamp`)
  return { timestamp, milliseconds }
}

const arguments_ = parseArguments(process.argv.slice(2))
const attestationPath = arguments_.get('--attestation')
let attestationBytes
let attestation
try {
  attestationBytes = fs.readFileSync(attestationPath)
  attestation = JSON.parse(attestationBytes.toString('utf8'))
} catch (error) {
  fail(`could not read attestation ${attestationPath}: ${error.message}`)
}

requireExactKeys(attestation, ['format', 'candidate', 'soak', 'machines', 'blockers'], 'attestation')
if (attestation.format !== FORMAT) fail(`attestation format must be ${FORMAT}`)

requireExactKeys(
  attestation.candidate,
  ['version', 'build', 'zipSHA256', 'dmgSHA256', 'provenanceSHA256', 'sourceCommit'],
  'attestation candidate',
)
const candidate = {
  version: requireVersion(attestation.candidate.version, 'attestation candidate version'),
  build: requireBuild(attestation.candidate.build, 'attestation candidate build'),
  zipSHA256: requireDigest(attestation.candidate.zipSHA256, 'attestation candidate ZIP digest'),
  dmgSHA256: requireDigest(attestation.candidate.dmgSHA256, 'attestation candidate DMG digest'),
  provenanceSHA256: requireDigest(
    attestation.candidate.provenanceSHA256,
    'attestation candidate provenance digest',
  ),
  sourceCommit: requireCommit(attestation.candidate.sourceCommit, 'attestation candidate source commit'),
}

const expected = {
  version: requireVersion(arguments_.get('--version'), 'expected version'),
  build: Number(arguments_.get('--build')),
  zipSHA256: requireDigest(arguments_.get('--zip-sha'), 'expected ZIP digest'),
  dmgSHA256: requireDigest(arguments_.get('--dmg-sha'), 'expected DMG digest'),
  provenanceSHA256: requireDigest(arguments_.get('--provenance-sha'), 'expected provenance digest'),
  sourceCommit: requireCommit(arguments_.get('--source-commit'), 'expected source commit'),
}
if (!Number.isSafeInteger(expected.build) || expected.build <= 0) {
  fail('expected build must be a positive integer')
}
for (const key of Object.keys(expected)) {
  if (candidate[key] !== expected[key]) fail(`attestation candidate ${key} does not match the artifact being promoted`)
}

requireExactKeys(attestation.soak, ['startedAt', 'completedAt'], 'attestation soak')
const started = requireTimestamp(attestation.soak.startedAt, 'soak startedAt')
const completed = requireTimestamp(attestation.soak.completedAt, 'soak completedAt')
const released = requireTimestamp(arguments_.get('--released-at'), 'candidate release time', {
  utcOnly: false,
})
if (started.milliseconds < released.milliseconds) {
  fail('soak startedAt cannot precede publication of the exact Daily candidate')
}
if (completed.milliseconds <= started.milliseconds) fail('soak completedAt must be later than startedAt')
const nowText = process.env.MECHANICIAN_PROMOTION_NOW || new Date().toISOString()
const now = requireTimestamp(nowText, 'current time')
if (completed.milliseconds > now.milliseconds) fail('soak completedAt cannot be in the future')
const soakMilliseconds = completed.milliseconds - started.milliseconds

const urgentReasonArgument = arguments_.get('--urgent-reason')
let urgentReason = null
if (urgentReasonArgument !== undefined) {
  urgentReason = requireString(urgentReasonArgument, 'urgent reason')
  if (urgentReason.length < 20 || urgentReason.length > 500) {
    fail('urgent reason must contain between 20 and 500 printable ASCII characters')
  }
}
if (soakMilliseconds < MINIMUM_SOAK_MILLISECONDS && urgentReason === null) {
  fail('stable promotion requires at least 24 hours of soak or an explicit urgent reason')
}

if (!Array.isArray(attestation.machines) || attestation.machines.length < 2) {
  fail('stable promotion requires smoke results from at least two machines')
}
const machineLabels = new Set()
for (const [index, machine] of attestation.machines.entries()) {
  const label = `attestation machine ${index + 1}`
  requireExactKeys(machine, ['label', 'version', 'build', 'zipSHA256', 'provenanceSHA256', 'checks'], label)
  const machineLabel = requireString(machine.label, `${label} label`)
  if (machineLabel.length > 80) fail(`${label} label must be 80 characters or fewer`)
  if (machineLabels.has(machineLabel)) fail('stable promotion requires distinct machine labels')
  machineLabels.add(machineLabel)
  if (requireVersion(machine.version, `${label} version`) !== candidate.version) {
    fail(`${label} version does not match the candidate`)
  }
  if (requireBuild(machine.build, `${label} build`) !== candidate.build) {
    fail(`${label} build does not match the candidate`)
  }
  if (requireDigest(machine.zipSHA256, `${label} ZIP digest`) !== candidate.zipSHA256) {
    fail(`${label} ZIP digest does not match the candidate`)
  }
  if (
    requireDigest(machine.provenanceSHA256, `${label} provenance digest`) !==
    candidate.provenanceSHA256
  ) {
    fail(`${label} provenance digest does not match the candidate`)
  }
  requireExactKeys(machine.checks, REQUIRED_CHECKS, `${label} checks`)
  for (const check of REQUIRED_CHECKS) {
    if (machine.checks[check] !== 'passed') fail(`${label} check ${check} must be passed`)
  }
}

if (!Array.isArray(attestation.blockers)) fail('attestation blockers must be an array')
if (attestation.blockers.length !== 0) fail('attestation contains unresolved blockers')

const attestationSHA256 = crypto.createHash('sha256').update(attestationBytes).digest('hex')
const record = {
  format: RECORD_FORMAT,
  candidate,
  attestationSHA256,
  machineCount: machineLabels.size,
  soakStartedAt: started.timestamp,
  soakCompletedAt: completed.timestamp,
  candidateReleasedAt: released.timestamp,
  soakHours: Number((soakMilliseconds / (60 * 60 * 1000)).toFixed(3)),
  urgent: urgentReason !== null,
  urgentReasonSHA256: urgentReason === null
    ? null
    : crypto.createHash('sha256').update(urgentReason).digest('hex'),
  checks: REQUIRED_CHECKS,
}
process.stdout.write(`${JSON.stringify(record, null, 2)}\n`)
