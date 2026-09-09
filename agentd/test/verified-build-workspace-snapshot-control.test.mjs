import assert from 'node:assert/strict'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { execFileSync, spawn } from 'node:child_process'
import { createHash } from 'node:crypto'
import { fileURLToPath } from 'node:url'
import { test } from 'node:test'

const here = path.dirname(fileURLToPath(import.meta.url))
const agentd = path.resolve(here, '../src/agentd.mjs')
const systemGit = '/usr/bin/git'

function runGit(cwd, args) {
  return execFileSync(systemGit, args, { cwd, encoding: 'utf8' }).trim()
}

function request(child, body) {
  child.stdin.write(`${JSON.stringify(body)}\n`)
}

async function waitFor(predicate, description, timeout = 10_000) {
  const deadline = Date.now() + timeout
  while (Date.now() < deadline) {
    const value = predicate()
    if (value) return value
    await new Promise((resolve) => setTimeout(resolve, 10))
  }
  assert.fail(`timed out waiting for ${description}`)
}

function startAgentd(t) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'mechanician-build-recapture-'))
  const config = path.join(root, 'config')
  const bin = path.join(root, 'bin')
  const toolLog = path.join(root, 'tool-arguments.log')
  fs.mkdirSync(config)
  fs.mkdirSync(bin)
  fs.symlinkSync(systemGit, path.join(bin, 'git'))
  fs.writeFileSync(path.join(bin, 'swift'), [
    '#!/bin/sh',
    'printf "%s\\n" "$*" >> "$MECHANICIAN_SNAPSHOT_TOOL_LOG"',
    'if [ "$1" = "--version" ] && [ "$#" = "1" ]; then',
    '  printf "Swift version snapshot-fixture\\n"',
    '  exit 0',
    'fi',
    'exit 93',
    '',
  ].join('\n'), { mode: 0o755 })

  const child = spawn(process.execPath, [agentd], {
    env: {
      ...process.env,
      MECHANICIAN_PROVIDER: 'anthropic',
      MECHANICIAN_AUTH: 'apikey',
      MECHANICIAN_CONFIG_DIR: config,
      MECHANICIAN_ENABLE_MOCK_PROVIDER: '1',
      MECHANICIAN_SNAPSHOT_TOOL_LOG: toolLog,
      OPENAI_API_KEY: '',
      ANTHROPIC_API_KEY: '',
      PATH: bin,
    },
    stdio: ['pipe', 'pipe', 'pipe'],
  })
  const events = []
  let buffered = ''
  child.stdout.setEncoding('utf8')
  child.stdout.on('data', (chunk) => {
    buffered += chunk
    const lines = buffered.split('\n')
    buffered = lines.pop() ?? ''
    for (const line of lines) if (line) events.push(JSON.parse(line))
  })
  t.after(() => {
    child.kill()
    fs.rmSync(root, { recursive: true, force: true })
  })
  return { child, events, root, bin, toolLog }
}

test('verified workspace recapture is exact, top-level-only, closed, and non-building', async (t) => {
  const { child, events, root, bin, toolLog } = startAgentd(t)
  const repo = path.join(root, 'repo')
  const nested = path.join(repo, 'nested')
  fs.mkdirSync(nested, { recursive: true })
  runGit(repo, ['init', '-q'])
  runGit(repo, ['config', 'user.name', 'Mechanician Test'])
  runGit(repo, ['config', 'user.email', 'mechanician@example.invalid'])
  fs.writeFileSync(path.join(repo, 'Package.swift'), '// snapshot fixture\n')
  runGit(repo, ['add', '--', 'Package.swift'])
  runGit(repo, ['commit', '-qm', 'fixture'])
  const headCommit = runGit(repo, ['rev-parse', '--verify', 'HEAD'])

  await waitFor(() => events.find((event) => event.type === 'ready'), 'ready')

  const availableID = '11111111-1111-4111-8111-111111111111'
  request(child, {
    type: 'verified_build_workspace_snapshot',
    id: availableID,
    cwd: repo,
    command: 'swift-build',
  })
  const available = await waitFor(
    () => events.find((event) => event.type === 'verified_build_workspace_snapshot_result'
      && event.id === availableID),
    'available workspace snapshot',
  )
  assert.deepEqual(Object.keys(available), [
    'type', 'id', 'command', 'status', 'reason', 'snapshot',
  ])
  assert.equal(available.command, 'swift-build')
  assert.equal(available.status, 'available')
  assert.equal(available.reason, null)
  assert.deepEqual(Object.keys(available.snapshot), [
    'rootSHA256', 'headCommit', 'dirtyTreeSHA256', 'toolchainSHA256',
  ])
  assert.equal(
    available.snapshot.rootSHA256,
    createHash('sha256').update(fs.realpathSync(repo)).digest('hex'),
  )
  assert.equal(available.snapshot.headCommit, headCommit)
  assert.match(available.snapshot.dirtyTreeSHA256, /^[0-9a-f]{64}$/)
  assert.match(available.snapshot.toolchainSHA256, /^[0-9a-f]{64}$/)
  assert.equal(fs.readFileSync(toolLog, 'utf8'), '--version\n')

  const unsupportedID = '22222222-2222-4222-8222-222222222222'
  request(child, {
    type: 'verified_build_workspace_snapshot',
    id: unsupportedID,
    cwd: repo,
    command: 'swift-test',
  })
  const unsupported = await waitFor(
    () => events.find((event) => event.id === unsupportedID),
    'unsupported command result',
  )
  assert.deepEqual(unsupported, {
    type: 'verified_build_workspace_snapshot_result',
    id: unsupportedID,
    command: null,
    status: 'unavailable',
    reason: 'unsupported_command',
    snapshot: null,
  })
  assert.equal(fs.readFileSync(toolLog, 'utf8'), '--version\n')

  const nestedID = '33333333-3333-4333-8333-333333333333'
  request(child, {
    type: 'verified_build_workspace_snapshot',
    id: nestedID,
    cwd: nested,
    command: 'swift-build',
  })
  const nonRoot = await waitFor(
    () => events.find((event) => event.id === nestedID),
    'non-root workspace result',
  )
  assert.deepEqual(nonRoot, {
    type: 'verified_build_workspace_snapshot_result',
    id: nestedID,
    command: 'swift-build',
    status: 'unavailable',
    reason: 'not_top_level_git_workspace',
    snapshot: null,
  })
  assert.equal(fs.readFileSync(toolLog, 'utf8'), '--version\n')

  const invalidID = '44444444-4444-4444-8444-444444444444'
  request(child, {
    type: 'verified_build_workspace_snapshot',
    id: invalidID,
    cwd: repo,
    command: 'swift-build',
    prompt: 'user-authored prose must not cross the result boundary',
  })
  const invalid = await waitFor(
    () => events.find((event) => event.id === invalidID),
    'invalid bounded request result',
  )
  assert.deepEqual(invalid, {
    type: 'verified_build_workspace_snapshot_result',
    id: invalidID,
    command: 'swift-build',
    status: 'unavailable',
    reason: 'invalid_request',
    snapshot: null,
  })
  assert.equal(JSON.stringify(invalid).includes('user-authored prose'), false)

  fs.unlinkSync(path.join(bin, 'swift'))
  const failedID = '55555555-5555-4555-8555-555555555555'
  request(child, {
    type: 'verified_build_workspace_snapshot',
    id: failedID,
    cwd: repo,
    command: 'swift-build',
  })
  const failed = await waitFor(
    () => events.find((event) => event.id === failedID),
    'snapshot failure result',
  )
  assert.deepEqual(failed, {
    type: 'verified_build_workspace_snapshot_result',
    id: failedID,
    command: 'swift-build',
    status: 'unavailable',
    reason: 'snapshot_failed',
    snapshot: null,
  })
})
