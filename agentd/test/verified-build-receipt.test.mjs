import assert from 'node:assert/strict'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { execFileSync } from 'node:child_process'
import test from 'node:test'
import {
  VERIFIED_BUILD_CORRELATION_FIELD,
  VERIFIED_BUILD_RECEIPT_SCHEMA,
  buildToolResultCorrelation,
  captureVerifiedBuildWorkspaceSnapshot,
  verifiedBuildDiagnosticsSHA256,
  verifiedBuildInvocationSHA256,
  verifiedBuildObservation,
  verifiedBuildSpec,
} from '../src/verified-build-receipt.mjs'

const snapshot = Object.freeze({
  rootSHA256: '1'.repeat(64),
  headCommit: '2'.repeat(40),
  dirtyTreeSHA256: '3'.repeat(64),
  toolchainSHA256: '4'.repeat(64),
})

test('only build commands have a receipt recipe', () => {
  assert.deepEqual(verifiedBuildSpec('swift-build'), {
    executable: 'swift', args: ['build'],
  })
  assert.deepEqual(verifiedBuildSpec('xcode-build'), {
    executable: 'xcodebuild', args: ['build'],
  })
  assert.equal(verifiedBuildObservation({
    command: 'swift-test', code: 0, diagnostics: [],
    before: snapshot, after: snapshot,
  }), null)
})

test('a stable successful build emits only closed facts and hashes', () => {
  const observation = verifiedBuildObservation({
    command: 'swift-build',
    code: 0,
    diagnostics: [{
      file: '/private/source/UserNamedFile.swift', line: 2, col: 3,
      severity: 'warning', message: 'user-authored diagnostic prose',
    }],
    before: snapshot,
    after: { ...snapshot },
    observedAt: new Date('2026-08-23T12:00:00.000Z'),
    correlationID: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
  })

  assert.equal(observation.schema, VERIFIED_BUILD_RECEIPT_SCHEMA)
  assert.equal(observation.lifecycle, 'succeeded')
  assert.equal(observation.effect, 'verification_execution')
  assert.equal(observation.exitCode, 0)
  assert.equal(observation.compilerErrorCount, 0)
  assert.match(observation.invocationSHA256, /^[0-9a-f]{64}$/)
  assert.match(observation.diagnosticsSHA256, /^[0-9a-f]{64}$/)
  const encoded = JSON.stringify(observation)
  assert.equal(encoded.includes('UserNamedFile'), false)
  assert.equal(encoded.includes('user-authored diagnostic prose'), false)
  assert.deepEqual(buildToolResultCorrelation(observation), {
    [VERIFIED_BUILD_CORRELATION_FIELD]: observation.correlationID,
  })
})

test('failure, compiler errors, source drift, and invalid correlation fail closed', () => {
  const base = {
    command: 'swift-build', code: 0, diagnostics: [],
    before: snapshot, after: snapshot,
    correlationID: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
  }
  assert.equal(verifiedBuildObservation({ ...base, code: 1 }), null)
  assert.equal(verifiedBuildObservation({
    ...base, diagnostics: [{ severity: 'error' }],
  }), null)
  assert.equal(verifiedBuildObservation({
    ...base, after: { ...snapshot, dirtyTreeSHA256: '5'.repeat(64) },
  }), null)
  assert.equal(verifiedBuildObservation({ ...base, correlationID: 'not-a-uuid' }), null)
  assert.deepEqual(buildToolResultCorrelation(null), {})
})

test('invocation and diagnostic digests are deterministic but input-sensitive', () => {
  assert.equal(
    verifiedBuildInvocationSHA256('swift-build', snapshot),
    verifiedBuildInvocationSHA256('swift-build', { ...snapshot }))
  assert.notEqual(
    verifiedBuildInvocationSHA256('swift-build', snapshot),
    verifiedBuildInvocationSHA256('xcode-build', snapshot))
  assert.equal(
    verifiedBuildDiagnosticsSHA256([{ severity: 'warning', message: 'x' }]),
    verifiedBuildDiagnosticsSHA256([{ severity: 'warning', message: 'x' }]))
  assert.notEqual(
    verifiedBuildDiagnosticsSHA256([{ severity: 'warning', message: 'x' }]),
    verifiedBuildDiagnosticsSHA256([{ severity: 'warning', message: 'y' }]))
})

test('real capture binds the top-level Git workspace and every dirty-tree state', async (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'mechanician-verified-build-'))
  t.after(() => fs.rmSync(root, { recursive: true, force: true }))
  execFileSync('git', ['init', '-q'], { cwd: root })
  fs.writeFileSync(path.join(root, 'Package.swift'), '// fixture\n')
  execFileSync('git', ['add', 'Package.swift'], { cwd: root })
  execFileSync('git', [
    '-c', 'user.name=Mechanician Tests', '-c', 'user.email=tests@example.invalid',
    'commit', '-qm', 'fixture',
  ], { cwd: root })

  const clean = await captureVerifiedBuildWorkspaceSnapshot(root, 'swift-build')
  assert.match(clean.rootSHA256, /^[0-9a-f]{64}$/)
  assert.match(clean.headCommit, /^[0-9a-f]{40,64}$/)
  assert.match(clean.dirtyTreeSHA256, /^[0-9a-f]{64}$/)
  assert.match(clean.toolchainSHA256, /^[0-9a-f]{64}$/)

  fs.writeFileSync(path.join(root, 'Untracked.swift'), '// exact untracked bytes\n')
  const dirty = await captureVerifiedBuildWorkspaceSnapshot(root, 'swift-build')
  assert.equal(dirty.rootSHA256, clean.rootSHA256)
  assert.equal(dirty.headCommit, clean.headCommit)
  assert.equal(dirty.toolchainSHA256, clean.toolchainSHA256)
  assert.notEqual(dirty.dirtyTreeSHA256, clean.dirtyTreeSHA256)

  const nested = path.join(root, 'Sources')
  fs.mkdirSync(nested)
  assert.equal(await captureVerifiedBuildWorkspaceSnapshot(nested, 'swift-build'), null)
  assert.equal(await captureVerifiedBuildWorkspaceSnapshot(root, 'swift-test'), null)
})

test('Claude and Codex production Build payloads retain observation and correlation', () => {
  const source = fs.readFileSync(new URL('../src/agentd.mjs', import.meta.url), 'utf8')
  const claudeStart = source.indexOf('const dev = createSdkMcpServer({')
  const claudeEnd = source.indexOf('// Computer use:', claudeStart)
  assert.ok(claudeStart >= 0 && claudeEnd > claudeStart)
  const claudeBuild = source.slice(claudeStart, claudeEnd)
  assert.match(claudeBuild,
    /verifiedKnowledgeObservation: r\.verifiedKnowledgeObservation \|\| undefined/)
  assert.match(claudeBuild,
    /\.\.\.buildToolResultCorrelation\(r\.verifiedKnowledgeObservation\)/)

  const codexStart = source.indexOf("    case 'Build': {\n      const command")
  const codexEnd = source.indexOf("    case 'CreateOrUpdateArtifact':", codexStart)
  assert.ok(codexStart >= 0 && codexEnd > codexStart)
  const codexBuild = source.slice(codexStart, codexEnd)
  assert.match(codexBuild,
    /verifiedKnowledgeObservation: r\.verifiedKnowledgeObservation \|\| undefined/)
  assert.match(codexBuild,
    /\.\.\.buildToolResultCorrelation\(r\.verifiedKnowledgeObservation\)/)

  const dynamicStart = source.indexOf('async function handleCodexDynamicToolCall(params)')
  const dynamicEnd = source.indexOf('function codexSandboxPolicy(', dynamicStart)
  assert.ok(dynamicStart >= 0 && dynamicEnd > dynamicStart)
  const dynamicRoute = source.slice(dynamicStart, dynamicEnd)
  assert.match(dynamicRoute, /executeOpenAITool\(ctx, name, input, toolUseId/)
  assert.match(dynamicRoute,
    /type: 'tool_result'.*result: output\.result,\s*status: 'success'/s)
})
