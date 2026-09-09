import assert from 'node:assert/strict'
import crypto from 'node:crypto'
import { once } from 'node:events'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { spawn } from 'node:child_process'
import { fileURLToPath } from 'node:url'
import { test } from 'node:test'

const here = path.dirname(fileURLToPath(import.meta.url))
const agentd = path.resolve(here, '../src/agentd.mjs')
const SOURCE_ID = '11111111-1111-4111-8111-111111111111'

function contentKey(value) {
  return crypto.createHash('sha256').update(value, 'utf8').digest('hex').slice(0, 24)
}

function versionLabel(version) {
  const label = String(version || 'unversioned')
    .replace(/[^A-Za-z0-9._-]+/g, '-')
    .replace(/^-+|-+$/g, '')
    .slice(0, 48)
  return label || 'unversioned'
}

function managedIdentity(installRoot, {
  sourceId = SOURCE_ID,
  pluginName,
  version,
  sha256,
}) {
  const sourceDirectory = path.join(installRoot, `source-${contentKey(sourceId)}`)
  const ownerDirectory = path.join(sourceDirectory, `plugin-${contentKey(pluginName)}`)
  const installPath = path.join(
    ownerDirectory,
    `v-${versionLabel(version)}-${sha256.slice(0, 16)}`,
  )
  return {
    sourceId,
    pluginName,
    version,
    sha256,
    installPath,
    sourceDirectory,
    ownerDirectory,
  }
}

function materialize(identity, installRoot) {
  for (const directory of [
    installRoot,
    identity.sourceDirectory,
    identity.ownerDirectory,
    identity.installPath,
  ]) {
    fs.mkdirSync(directory, { recursive: true, mode: 0o700 })
    fs.chmodSync(directory, 0o700)
  }
  fs.writeFileSync(path.join(identity.installPath, 'fixture.txt'), 'fixture\n', { mode: 0o600 })
}

function createLease(installRoot, identity, token) {
  const directory = path.join(installRoot, '.leases')
  fs.mkdirSync(directory, { recursive: true, mode: 0o700 })
  fs.chmodSync(directory, 0o700)
  const file = path.join(directory, `${token}.json`)
  fs.writeFileSync(file, JSON.stringify({
    token,
    sourceId: identity.sourceId,
    pluginName: identity.pluginName,
    version: identity.version,
    sha256: identity.sha256,
    installPath: identity.installPath,
    createdAt: Date.now(),
    ownerPid: process.pid,
    clientPid: process.ppid,
  }), { mode: 0o600 })
  fs.chmodSync(file, 0o600)
  return file
}

function startAgentd(t, support) {
  const config = path.join(support, 'config')
  fs.mkdirSync(config, { mode: 0o700 })
  const child = spawn(process.execPath, [agentd], {
    env: {
      ...process.env,
      HOME: support,
      MECHANICIAN_SUPPORT_DIR: support,
      MECHANICIAN_CONFIG_DIR: config,
      MECHANICIAN_PROVIDER: 'anthropic',
      MECHANICIAN_AUTH: 'apikey',
      MECHANICIAN_ENABLE_MOCK_PROVIDER: '1',
      OPENAI_API_KEY: '',
      ANTHROPIC_API_KEY: '',
      CLAUDE_CODE_OAUTH_TOKEN: '',
      PATH: config,
    },
    stdio: ['pipe', 'pipe', 'pipe'],
  })
  const events = []
  let stdout = ''
  let stderr = ''
  child.stdout.setEncoding('utf8')
  child.stdout.on('data', (chunk) => {
    stdout += chunk
    const lines = stdout.split('\n')
    stdout = lines.pop() ?? ''
    for (const line of lines) if (line) events.push(JSON.parse(line))
  })
  child.stderr.setEncoding('utf8')
  child.stderr.on('data', (chunk) => { stderr += chunk })
  t.after(async () => {
    if (child.exitCode !== null) return
    child.kill('SIGTERM')
    await Promise.race([
      once(child, 'exit'),
      new Promise((resolve) => setTimeout(resolve, 1_000)),
    ])
    if (child.exitCode === null) child.kill('SIGKILL')
  })
  return { child, events, stderr: () => stderr }
}

async function waitFor(predicate, description, diagnostics, timeout = 5_000) {
  const deadline = Date.now() + timeout
  while (Date.now() < deadline) {
    const value = predicate()
    if (value) return value
    await new Promise((resolve) => setTimeout(resolve, 10))
  }
  assert.fail(`timed out waiting for ${description}: ${diagnostics()}`)
}

function send(child, request) {
  child.stdin.write(`${JSON.stringify({ type: 'claude_plugins', ...request })}\n`)
}

test('archive lifecycle actions dispatch through agentd with exact status and correlation', async (t) => {
  const support = fs.mkdtempSync(path.join(os.tmpdir(), 'mechanician-archive-dispatch-'))
  t.after(() => fs.rmSync(support, { recursive: true, force: true }))
  const installRoot = path.join(support, 'plugin-archives')
  const extensionsFile = path.join(support, 'extensions.json')

  const removable = managedIdentity(installRoot, {
    pluginName: 'operations',
    version: '1.0.0',
    sha256: 'a'.repeat(64),
  })
  const finalizable = managedIdentity(installRoot, {
    pluginName: 'mounted-operations',
    version: '2.0 beta',
    sha256: 'b'.repeat(64),
  })
  materialize(removable, installRoot)
  materialize(finalizable, installRoot)
  fs.writeFileSync(extensionsFile, JSON.stringify({ plugins: [] }))

  const leaseToken = '123e4567-e89b-42d3-a456-426614174000'
  const leaseFile = createLease(installRoot, finalizable, leaseToken)
  const { child, events, stderr } = startAgentd(t, support)
  const diagnostic = () => `${stderr()}\nevents=${JSON.stringify(events)}`
  await waitFor(() => events.find((event) => event.type === 'ready'), 'ready', diagnostic)

  send(child, {
    id: 'install-invalid-url',
    action: 'installArchive',
    pluginId: 'operations@archive-fixture',
    operationId: 'install-operation',
    sourceId: SOURCE_ID,
    sourceName: 'Fixture',
    pluginName: 'operations',
    version: '1.0.0',
    archiveUrl: 'http://plugins.example/operations.tar.gz',
    catalogUrl: 'https://plugins.example/registry.json',
    sha256: 'a'.repeat(64),
  })
  const invalidInstall = await waitFor(
    () => events.find((event) => event.id === 'install-invalid-url'),
    'invalid archive install rejection',
    diagnostic,
  )
  assert.deepEqual(invalidInstall, {
    type: 'claude_plugins_result',
    id: 'install-invalid-url',
    action: 'installArchive',
    ok: false,
    pluginId: 'operations@archive-fixture',
    operationId: 'install-operation',
    message: 'Managed plugin archive URL must use HTTPS.',
  })

  const removalCorrelation = {
    pluginId: 'operations@archive-fixture',
    background: true,
    operationId: 'remove-operation',
    cleanupId: 'remove-cleanup',
  }
  send(child, {
    id: 'remove-present',
    action: 'removeArchive',
    ...removalCorrelation,
    ...removable,
  })
  const removed = await waitFor(
    () => events.find((event) => event.id === 'remove-present'),
    'first archive removal',
    diagnostic,
  )
  assert.deepEqual(removed, {
    type: 'claude_plugins_result',
    id: 'remove-present',
    action: 'removeArchive',
    ok: true,
    ...removalCorrelation,
    removal: {
      status: 'removed',
      removed: true,
      retryAfterMilliseconds: null,
    },
  })
  assert.equal(fs.existsSync(removable.installPath), false)

  send(child, {
    id: 'remove-missing',
    action: 'removeArchive',
    ...removalCorrelation,
    ...removable,
  })
  const missing = await waitFor(
    () => events.find((event) => event.id === 'remove-missing'),
    'second archive removal',
    diagnostic,
  )
  assert.deepEqual(missing, {
    type: 'claude_plugins_result',
    id: 'remove-missing',
    action: 'removeArchive',
    ok: true,
    ...removalCorrelation,
    removal: {
      status: 'missing',
      removed: false,
      retryAfterMilliseconds: null,
    },
  })

  const finalizeCorrelation = {
    pluginId: 'mounted-operations@archive-fixture',
    background: true,
    operationId: 'finalize-operation',
    cleanupId: 'finalize-cleanup',
    finalizationId: 'finalize-record',
  }
  send(child, {
    id: 'finalize-unmounted',
    action: 'finalizeArchive',
    ...finalizeCorrelation,
    ...finalizable,
    leaseToken,
  })
  const unmounted = await waitFor(
    () => events.find((event) => event.id === 'finalize-unmounted'),
    'unmounted finalization rejection',
    diagnostic,
  )
  assert.equal(unmounted.ok, false)
  assert.equal(unmounted.action, 'finalizeArchive')
  for (const [key, value] of Object.entries(finalizeCorrelation)) {
    assert.equal(unmounted[key], value)
  }
  assert.match(unmounted.message, /cannot be finalized before its mount is saved/i)
  assert.equal(fs.existsSync(leaseFile), true)

  fs.writeFileSync(extensionsFile, JSON.stringify({
    plugins: [{ enabled: false, path: finalizable.installPath }],
  }))
  send(child, {
    id: 'finalize-mounted',
    action: 'finalizeArchive',
    ...finalizeCorrelation,
    ...finalizable,
    leaseToken,
  })
  const finalized = await waitFor(
    () => events.find((event) => event.id === 'finalize-mounted'),
    'mounted archive finalization',
    diagnostic,
  )
  assert.deepEqual(finalized, {
    type: 'claude_plugins_result',
    id: 'finalize-mounted',
    action: 'finalizeArchive',
    ok: true,
    ...finalizeCorrelation,
  })
  assert.equal(fs.existsSync(leaseFile), false)
  assert.equal(fs.existsSync(finalizable.installPath), true)

  send(child, {
    id: 'reconcile',
    action: 'reconcileArchives',
    pluginId: finalizeCorrelation.pluginId,
    background: true,
    operationId: 'reconcile-operation',
  })
  const reconciled = await waitFor(
    () => events.find((event) => event.id === 'reconcile'),
    'archive reconciliation',
    diagnostic,
  )
  assert.deepEqual(reconciled, {
    type: 'claude_plugins_result',
    id: 'reconcile',
    action: 'reconcileArchives',
    ok: true,
    pluginId: finalizeCorrelation.pluginId,
    background: true,
    operationId: 'reconcile-operation',
    reconciliation: {
      removedPaths: 0,
      removedLeases: 0,
      retryAfterMilliseconds: null,
    },
  })

  child.kill('SIGTERM')
  const [code, signal] = await once(child, 'exit')
  assert.equal(code, 0, diagnostic())
  assert.equal(signal, null, diagnostic())
})
