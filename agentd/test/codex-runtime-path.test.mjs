import assert from 'node:assert/strict'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import test from 'node:test'

import { codexRuntimePATH, codexRuntimeTools } from '../src/codex-runtime-path.mjs'
import {
  isUnsupported, REQUIRES_CHATGPT_APP, unsupportedReason,
} from '../src/codex-plugin-viability.mjs'

function runtimeHome({ override = ['soffice', 'pdftoppm'], fallback = ['git'] } = {}) {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'codex-rt-'))
  const bin = path.join(home, '.cache', 'codex-runtimes', 'codex-primary-runtime', 'dependencies', 'bin')
  for (const [kind, names] of [['override', override], ['fallback', fallback]]) {
    if (!names.length) continue
    fs.mkdirSync(path.join(bin, kind), { recursive: true })
    for (const name of names) fs.writeFileSync(path.join(bin, kind, name), '')
  }
  return home
}

const dirs = (p) => p.split(path.delimiter)

test('override goes first and fallback goes last, which is what those names mean', () => {
  const home = runtimeHome()
  const result = dirs(codexRuntimePATH('/usr/bin:/bin', { home }))

  // An overriding soffice must beat the user's LibreOffice: the plugins are written against this
  // specific headless build.
  assert.match(result[0], /bin\/override$/)
  // A fallback git must only be reached when the user has none.
  assert.match(result[result.length - 1], /bin\/fallback$/)
  assert.deepEqual(result.slice(1, -1), ['/usr/bin', '/bin'])
})

test('a machine without the runtime gets its PATH back unchanged', () => {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'codex-none-'))
  assert.equal(codexRuntimePATH('/usr/bin:/bin', { home }), '/usr/bin:/bin')
  assert.deepEqual(codexRuntimeTools(home), [])
})

test('re-running never grows PATH, so a restart loop cannot unbound it', () => {
  const home = runtimeHome()
  const once = codexRuntimePATH('/usr/bin', { home })
  assert.equal(codexRuntimePATH(once, { home }), once)
  assert.equal(codexRuntimePATH(codexRuntimePATH(once, { home }), { home }), once)
})

test('only the half that exists is added', () => {
  const home = runtimeHome({ fallback: [] })
  const result = dirs(codexRuntimePATH('/usr/bin', { home }))
  assert.equal(result.length, 2)
  assert.match(result[0], /bin\/override$/)
})

test('an empty inbound PATH does not produce empty entries', () => {
  const home = runtimeHome()
  assert.ok(!dirs(codexRuntimePATH('', { home })).includes(''))
  assert.ok(!dirs(codexRuntimePATH(undefined, { home })).includes(''))
})

test('the tools it supplies are named, so a capability change is visible in the log', () => {
  const home = runtimeHome()
  assert.deepEqual(codexRuntimeTools(home), ['git', 'pdftoppm', 'soffice'])
})

// The viability gate lives next door and answers the same question — "will this actually work
// here?" — so it is pinned in the same place.

test('the two plugins that need the ChatGPT app are hidden, with a reason', () => {
  for (const name of ['browser', 'chrome']) {
    const id = `${name}@openai-bundled`
    assert.ok(isUnsupported({ pluginId: id, installed: false }), name)
    assert.ok(unsupportedReason(id), `${name} must say why`)
  }
})

test('everything measured to work is offered — fixed or proven, never hidden on a hunch', () => {
  // computer-use and record-and-replay were hidden as UNKNOWN and are not: their signed .app
  // survives codex's copy into plugins/cache, Gatekeeper accepts it, and both MCP servers start
  // from the copy and list their tools.
  for (const name of ['visualize', 'documents', 'pdf', 'latex', 'presentations',
                      'computer-use', 'record-and-replay', 'sites']) {
    assert.ok(!isUnsupported({ pluginId: `${name}@openai-bundled`, installed: false }), name)
  }
})

test('an already-installed plugin is never hidden, because it would become unremovable', () => {
  assert.ok(!isUnsupported({ pluginId: 'browser@openai-bundled', installed: true }))
})

test('exactly two remain hidden, and each is blocked on a piece of the ChatGPT app', () => {
  // A count guard: hiding is a claim about viability, and the list growing quietly would mean the
  // app is withholding more than anyone decided it should.
  assert.equal(REQUIRES_CHATGPT_APP.size, 2)
})

test('anything unlisted stays visible, so an OpenAI update surfaces rather than vanishes', () => {
  assert.ok(!isUnsupported({ pluginId: 'something-new@openai-bundled', installed: false }))
  assert.equal(unsupportedReason('something-new@openai-bundled'), null)
})
