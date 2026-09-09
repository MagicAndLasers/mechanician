import assert from 'node:assert/strict'
import { createHash } from 'node:crypto'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { spawnSync } from 'node:child_process'
import { fileURLToPath } from 'node:url'
import { test } from 'node:test'

const here = path.dirname(fileURLToPath(import.meta.url))
const repo = path.resolve(here, '../..')
const validator = path.join(repo, 'scripts/validate-stable-promotion.mjs')
const digest = character => character.repeat(64)
const commit = 'd'.repeat(40)
const expected = {
  version: '0.26.24',
  build: 239,
  zipSHA256: digest('a'),
  dmgSHA256: digest('b'),
  provenanceSHA256: digest('c'),
  sourceCommit: commit,
}
const checks = {
  launch: 'passed',
  update: 'passed',
  storage: 'passed',
  claude: 'passed',
  codex: 'passed',
  backgroundProcesses: 'passed',
  crashFree: 'passed',
}

function attestation(overrides = {}) {
  const base = {
    format: 'ai.mechanician.stable-promotion-attestation.v1',
    candidate: { ...expected },
    soak: {
      startedAt: '2026-08-10T10:00:00Z',
      completedAt: '2026-08-11T10:00:00Z',
    },
    machines: ['studio', 'laptop'].map(label => ({
      label,
      version: expected.version,
      build: expected.build,
      zipSHA256: expected.zipSHA256,
      provenanceSHA256: expected.provenanceSHA256,
      checks: { ...checks },
    })),
    blockers: [],
  }
  return { ...base, ...overrides }
}

function run(t, document, extraArguments = []) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'mechanician-promotion-attestation-'))
  t.after(() => fs.rmSync(root, { recursive: true, force: true }))
  const file = path.join(root, 'attestation.json')
  fs.writeFileSync(file, `${JSON.stringify(document, null, 2)}\n`)
  return spawnSync(process.execPath, [
    validator,
    '--attestation', file,
    '--version', expected.version,
    '--build', String(expected.build),
    '--zip-sha', expected.zipSHA256,
    '--dmg-sha', expected.dmgSHA256,
    '--provenance-sha', expected.provenanceSHA256,
    '--source-commit', expected.sourceCommit,
    '--released-at', '2026-08-10T09:59:00Z',
    ...extraArguments,
  ], {
    encoding: 'utf8',
    env: { ...process.env, MECHANICIAN_PROMOTION_NOW: '2026-08-12T10:00:00Z' },
  })
}

test('accepts an exact candidate after two-machine 24-hour smoke and emits a sanitized record', t => {
  const result = run(t, attestation())
  assert.equal(result.status, 0, result.stderr)
  const record = JSON.parse(result.stdout)
  assert.equal(record.format, 'ai.mechanician.stable-promotion-authorization.v1')
  assert.deepEqual(record.candidate, expected)
  assert.equal(record.machineCount, 2)
  assert.equal(record.soakHours, 24)
  assert.equal(record.urgent, false)
  assert.equal(record.urgentReasonSHA256, null)
  assert.match(record.attestationSHA256, /^[0-9a-f]{64}$/)
  assert.doesNotMatch(result.stdout, /studio|laptop/)
})

test('refuses a candidate digest mismatch', t => {
  const document = attestation()
  document.candidate.zipSHA256 = digest('e')
  const result = run(t, document)
  assert.notEqual(result.status, 0)
  assert.match(result.stderr, /zipSHA256 does not match/i)
})

test('refuses duplicate machines and any failed smoke check', async t => {
  const duplicate = attestation()
  duplicate.machines[1].label = duplicate.machines[0].label
  let result = run(t, duplicate)
  assert.notEqual(result.status, 0)
  assert.match(result.stderr, /distinct machine labels/)

  const failed = attestation()
  failed.machines[1].checks.codex = 'failed'
  result = run(t, failed)
  assert.notEqual(result.status, 0)
  assert.match(result.stderr, /check codex must be passed/)
})

test('refuses unresolved blockers and malformed check schemas', t => {
  const blocked = attestation({ blockers: ['crash under load'] })
  let result = run(t, blocked)
  assert.notEqual(result.status, 0)
  assert.match(result.stderr, /unresolved blockers/)

  const typo = attestation()
  typo.machines[0].checks.provider = 'passed'
  result = run(t, typo)
  assert.notEqual(result.status, 0)
  assert.match(result.stderr, /must contain exactly/)
})

test('requires 24 hours unless a meaningful urgent reason is recorded', t => {
  const short = attestation({
    soak: {
      startedAt: '2026-08-11T09:00:00Z',
      completedAt: '2026-08-11T10:00:00Z',
    },
  })
  let result = run(t, short)
  assert.notEqual(result.status, 0)
  assert.match(result.stderr, /at least 24 hours/)

  result = run(t, short, ['--urgent-reason', 'Critical user recovery fix needs immediate promotion.'])
  assert.equal(result.status, 0, result.stderr)
  const record = JSON.parse(result.stdout)
  assert.equal(record.urgent, true)
  assert.equal(record.urgentReason, undefined)
  assert.equal(
    record.urgentReasonSHA256,
    createHash('sha256').update('Critical user recovery fix needs immediate promotion.').digest('hex'),
  )
})

test('soak cannot claim time before the exact Daily candidate was released', t => {
  const document = attestation()
  document.soak.startedAt = '2026-08-10T09:58:00Z'
  const result = run(t, document)
  assert.notEqual(result.status, 0)
  assert.match(result.stderr, /cannot precede publication/)
})

test('an urgent promotion never waives candidate or two-machine checks', t => {
  const oneMachine = attestation({
    soak: {
      startedAt: '2026-08-11T09:00:00Z',
      completedAt: '2026-08-11T10:00:00Z',
    },
  })
  oneMachine.machines = oneMachine.machines.slice(0, 1)
  const result = run(t, oneMachine, [
    '--urgent-reason',
    'Critical user recovery fix needs immediate promotion.',
  ])
  assert.notEqual(result.status, 0)
  assert.match(result.stderr, /at least two machines/)
})

test('refuses future soak completion and noncanonical input fields', async t => {
  const future = attestation({
    soak: {
      startedAt: '2026-08-12T10:00:00Z',
      completedAt: '2026-08-13T10:00:00Z',
    },
  })
  let result = run(t, future)
  assert.notEqual(result.status, 0)
  assert.match(result.stderr, /cannot be in the future/)

  const extra = attestation({ operator: 'somebody' })
  result = run(t, extra)
  assert.notEqual(result.status, 0)
  assert.match(result.stderr, /must contain exactly/)
})
