import assert from 'node:assert/strict'
import fs from 'node:fs'
import path from 'node:path'
import { execFileSync } from 'node:child_process'
import { fileURLToPath } from 'node:url'
import { test } from 'node:test'

import {
  BUNDLED_CODEX_VERSION,
  bundledCodexPath,
  codexBinaryCandidates,
  resolveCodexBinary,
} from '../src/codex-runtime.mjs'

const here = path.dirname(fileURLToPath(import.meta.url))
const agentdDirectory = path.resolve(here, '../src')
const expectedBundled = path.resolve(
  here,
  '../node_modules/@openai/codex-darwin-arm64/vendor/aarch64-apple-darwin/bin/codex',
)

test('explicit Codex developer override precedes the bundled runtime', () => {
  const candidates = codexBinaryCandidates({
    environment: { MECHANICIAN_CODEX_BIN: '/tmp/developer-codex' },
    agentdDirectory,
    homeDirectory: '/tmp/home',
    platform: 'darwin',
    architecture: 'arm64',
  })
  assert.equal(candidates[0], '/tmp/developer-codex')
  assert.equal(candidates[1], expectedBundled)
})

test('bundled Codex is resolved before legacy system installations', () => {
  const resolved = resolveCodexBinary({
    environment: {},
    agentdDirectory,
    homeDirectory: '/tmp/home',
    platform: 'darwin',
    architecture: 'arm64',
    isExecutable: (candidate) => candidate === expectedBundled
      || candidate === '/Applications/ChatGPT.app/Contents/Resources/codex',
    which: () => null,
  })
  assert.equal(resolved, expectedBundled)
  assert.equal(bundledCodexPath(agentdDirectory), expectedBundled)
})

test('locked darwin-arm64 Codex binary runs and reports the pinned version', () => {
  const packageJSON = JSON.parse(fs.readFileSync(
    path.resolve(here, '../node_modules/@openai/codex/package.json'),
    'utf8',
  ))
  assert.equal(packageJSON.version, BUNDLED_CODEX_VERSION)
  assert.equal(fs.statSync(expectedBundled).mode & 0o111, 0o111)
  assert.equal(
    execFileSync(expectedBundled, ['--version'], { encoding: 'utf8' }).trim(),
    `codex-cli ${BUNDLED_CODEX_VERSION}`,
  )
})
