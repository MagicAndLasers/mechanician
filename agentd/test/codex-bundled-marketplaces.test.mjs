import assert from 'node:assert/strict'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import test from 'node:test'

import {
  discoverBundledMarketplaces, ensureBundledMarketplaces,
} from '../src/codex-bundled-marketplaces.mjs'

/// A fake filesystem laid out exactly like a real Mac: a ChatGPT app bundle (in /Applications and/or
/// ~/Applications) and the primary runtime the app downloads into ~/.cache. Nothing here touches the
/// developer's own install — `applications` is injected precisely so these stay hermetic.
function fakeMachine({ system = [], user = [], runtime = ['openai-primary-runtime'] } = {}) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'codex-bundled-'))
  const home = path.join(root, 'home')
  const applications = path.join(root, 'Applications')
  const marketplace = (dir, name) => {
    fs.mkdirSync(path.join(dir, '.agents', 'plugins'), { recursive: true })
    fs.writeFileSync(path.join(dir, '.agents', 'plugins', 'marketplace.json'),
      JSON.stringify({ name, plugins: [{ name: 'latex' }] }))
  }
  const chatGPT = (base) => path.join(base, 'ChatGPT.app', 'Contents', 'Resources', 'plugins')
  for (const name of system) marketplace(path.join(chatGPT(applications), name), name)
  for (const name of user) marketplace(path.join(chatGPT(path.join(home, 'Applications')), name), name)
  for (const name of runtime) {
    marketplace(
      path.join(home, '.cache', 'codex-runtimes', 'codex-primary-runtime', 'plugins', name), name)
  }
  return { root, home, applications }
}

const discoverIn = (machine, overrides = {}) =>
  discoverBundledMarketplaces({ home: machine.home, applications: machine.applications, ...overrides })

/// Records what it was asked, so a test can assert on the wire rather than on our reading of it.
function fakeApp({ known = [], addResult = { alreadyAdded: false }, failAdd = false } = {}) {
  const calls = []
  return {
    calls,
    adds: () => calls.filter((c) => c.method === 'marketplace/add'),
    async request(method, params) {
      calls.push({ method, params })
      if (method === 'plugin/list') return { marketplaces: known.map((name) => ({ name })) }
      if (method === 'marketplace/add') {
        if (failAdd) throw new Error('marketplace/add exploded')
        return addResult
      }
      return {}
    },
  }
}

test('both the app bundle and the downloaded runtime are discovered, with absolute sources', () => {
  const machine = fakeMachine({ system: ['openai-bundled'] })

  const found = discoverIn(machine)

  assert.deepEqual(found.map((m) => m.name).sort(), ['openai-bundled', 'openai-primary-runtime'])
  assert.ok(found.every((m) => path.isAbsolute(m.source)))
})

test('the name comes from the manifest, not from the directory', () => {
  // Internal ChatGPT builds ship `openai-bundled-alpha` under the same layout. Trusting the
  // directory name would register it under the wrong identity and defeat the skip check.
  const machine = fakeMachine({ system: [], runtime: [] })
  const dir = path.join(machine.applications, 'ChatGPT.app', 'Contents', 'Resources', 'plugins', 'whatever')
  fs.mkdirSync(path.join(dir, '.agents', 'plugins'), { recursive: true })
  fs.writeFileSync(path.join(dir, '.agents', 'plugins', 'marketplace.json'),
    JSON.stringify({ name: 'openai-bundled-alpha' }))

  assert.deepEqual(discoverIn(machine), [{ name: 'openai-bundled-alpha', source: dir }])
})

test('a system install wins over a per-user copy of the same marketplace', () => {
  const machine = fakeMachine({ system: ['openai-bundled'], user: ['openai-bundled'], runtime: [] })

  const found = discoverIn(machine)

  assert.equal(found.length, 1)
  assert.ok(found[0].source.startsWith(machine.applications))
})

test('a directory without a marketplace manifest is not a marketplace', () => {
  const machine = fakeMachine({ system: ['openai-bundled'], runtime: [] })
  fs.mkdirSync(
    path.join(machine.applications, 'ChatGPT.app', 'Contents', 'Resources', 'plugins', 'stray'),
    { recursive: true })

  assert.deepEqual(discoverIn(machine).map((m) => m.name), ['openai-bundled'])
})

test('a malformed manifest is skipped rather than throwing', () => {
  const machine = fakeMachine({ system: ['openai-bundled'], runtime: [] })
  const broken = path.join(
    machine.applications, 'ChatGPT.app', 'Contents', 'Resources', 'plugins', 'broken', '.agents', 'plugins')
  fs.mkdirSync(broken, { recursive: true })
  fs.writeFileSync(path.join(broken, 'marketplace.json'), '{ not json')

  assert.deepEqual(discoverIn(machine).map((m) => m.name), ['openai-bundled'])
})

test('a Mac without the ChatGPT app discovers nothing, and that is not an error', async () => {
  const machine = fakeMachine({ system: [], user: [], runtime: [] })
  const app = fakeApp()

  assert.deepEqual(discoverIn(machine), [])
  const result = await ensureBundledMarketplaces({ app, discover: () => discoverIn(machine) })
  assert.deepEqual(result, { added: [], skipped: [], failed: [] })
  assert.equal(app.calls.length, 0, 'nothing to register means nothing to ask the server')
})

test('marketplaces the home already knows are skipped rather than re-added', async () => {
  const machine = fakeMachine({ system: ['openai-bundled'] })
  const app = fakeApp({ known: ['openai-bundled', 'openai-primary-runtime', 'openai-curated-remote'] })

  const result = await ensureBundledMarketplaces({ app, discover: () => discoverIn(machine) })

  assert.deepEqual(result.skipped.sort(), ['openai-bundled', 'openai-primary-runtime'])
  assert.equal(app.adds().length, 0,
    'a second launch must not re-add what codex already persisted')
})

test('an unknown marketplace is added by absolute source path', async () => {
  const machine = fakeMachine({ system: ['openai-bundled'], runtime: [] })
  const app = fakeApp({ known: ['openai-curated-remote'] })

  const result = await ensureBundledMarketplaces({ app, discover: () => discoverIn(machine) })

  assert.deepEqual(result.added, ['openai-bundled'])
  assert.deepEqual(app.adds()[0].params, {
    source: path.join(machine.applications, 'ChatGPT.app', 'Contents', 'Resources', 'plugins', 'openai-bundled'),
  })
})

test('bundled marketplace registration uses the shared config mutation boundary', async () => {
  const machine = fakeMachine({ system: ['openai-bundled'], runtime: [] })
  const app = fakeApp({ known: [] })
  let boundaries = 0

  const result = await ensureBundledMarketplaces({
    app,
    discover: () => discoverIn(machine),
    mutateConfig: async (work) => {
      boundaries += 1
      return work()
    },
  })

  assert.deepEqual(result.added, ['openai-bundled'])
  assert.equal(boundaries, 1)
})

test("the server's own alreadyAdded counts as skipped, not added", async () => {
  const machine = fakeMachine({ system: ['openai-bundled'], runtime: [] })
  const app = fakeApp({ known: [], addResult: { alreadyAdded: true } })

  const result = await ensureBundledMarketplaces({ app, discover: () => discoverIn(machine) })

  assert.deepEqual(result.added, [])
  assert.deepEqual(result.skipped, ['openai-bundled'])
})

test('a failing add is reported without throwing, so lane startup is never blocked', async () => {
  const machine = fakeMachine({ system: ['openai-bundled'], runtime: [] })
  const app = fakeApp({ known: [], failAdd: true })

  const result = await ensureBundledMarketplaces({ app, discover: () => discoverIn(machine) })

  assert.deepEqual(result.added, [])
  assert.equal(result.failed.length, 1)
  assert.match(result.failed[0].message, /exploded/)
})

test('a listing failure still attempts registration, because add is safe to repeat', async () => {
  const machine = fakeMachine({ system: ['openai-bundled'] })
  const calls = []
  const app = {
    async request(method, params) {
      calls.push({ method, params })
      if (method === 'plugin/list') throw new Error('list unavailable')
      return { alreadyAdded: true }
    },
  }

  const result = await ensureBundledMarketplaces({ app, discover: () => discoverIn(machine) })

  assert.equal(calls.filter((c) => c.method === 'marketplace/add').length, 2)
  assert.deepEqual(result.skipped.sort(), ['openai-bundled', 'openai-primary-runtime'])
})

test('no app means no work at all', async () => {
  assert.deepEqual(await ensureBundledMarketplaces({ app: null }),
    { added: [], skipped: [], failed: [] })
})
