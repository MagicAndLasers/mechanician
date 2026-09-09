import assert from 'node:assert/strict'
import test from 'node:test'

import { createCodexPlugins } from '../src/codex-plugins.mjs'

// A marketplace pair that covers the one asymmetry in the protocol: a LOCAL marketplace has a
// `path` and resolves plugins by name; a REMOTE one has no path and resolves them by
// `remotePluginId`. It applies to install AND uninstall, and both shipped wrong once — install
// 404ing against the server's own catalog, uninstall returning `{}` and removing nothing.
const MARKETPLACES = [
  {
    name: 'openai-bundled',
    path: '/tmp/bundled/marketplace.json',
    plugins: [
      {
        id: 'latex@openai-bundled',
        name: 'latex',
        installed: false,
        interface: { displayName: 'LaTeX', shortDescription: 'Typeset documents' },
      },
    ],
  },
  {
    name: 'openai-curated-remote',
    path: null,
    plugins: [
      {
        id: 'sales@openai-curated-remote',
        name: 'sales',
        remotePluginId: 'Plugin_af5b4b796b588191b3f2c610aa093799',
        installed: false,
        localVersion: null,
        version: '1.0.8',
        availability: 'AVAILABLE',
        installPolicy: 'AVAILABLE',
        mustShowInstallationInterstitial: false,
        interface: {
          displayName: 'Sales',
          shortDescription: 'Practical workflows for sellers',
          developerName: 'OpenAI',
          category: 'Business & Operations',
          logoUrl: 'https://files.openai.com/logo.png',
        },
      },
    ],
  },
]

/// A stand-in app-server that records what it was asked, so a test can assert on the wire shape
/// rather than on our own re-reading of it.
function fakeApp(marketplaces = MARKETPLACES) {
  const calls = []
  return {
    calls,
    async request(method, params) {
      calls.push({ method, params })
      if (method === 'plugin/list') return { marketplaces }
      return {}
    },
  }
}

test('a remote marketplace installs by remotePluginId, a local one by name', async () => {
  const app = fakeApp()
  const plugins = createCodexPlugins({ app })

  await plugins.install('sales@openai-curated-remote')
  await plugins.install('latex@openai-bundled')

  const installs = app.calls.filter((c) => c.method === 'plugin/install')
  assert.deepEqual(installs[0].params, {
    pluginName: 'Plugin_af5b4b796b588191b3f2c610aa093799',
    remoteMarketplaceName: 'openai-curated-remote',
  })
  assert.deepEqual(installs[1].params, {
    pluginName: 'latex',
    marketplacePath: '/tmp/bundled/marketplace.json',
  })
})

test('every config-mutating plugin RPC runs inside the shared mutation boundary', async () => {
  let insideMutation = false
  const app = fakeApp()
  const originalRequest = app.request
  app.request = async (method, params) => {
    if (method !== 'plugin/list') {
      assert.equal(insideMutation, true, `${method} escaped the config mutation boundary`)
    }
    return originalRequest(method, params)
  }
  const mutateConfig = async (work) => {
    assert.equal(insideMutation, false)
    insideMutation = true
    try { return await work() } finally { insideMutation = false }
  }
  const plugins = createCodexPlugins({ app, mutateConfig })

  await plugins.install('sales@openai-curated-remote')
  await plugins.uninstall('sales@openai-curated-remote')
  await plugins.addMarketplace('owner/repository')
  await plugins.removeMarketplace('third-party')
  await plugins.upgradeMarketplace('third-party')

  assert.equal(insideMutation, false)
})

test('install sends exactly one of marketplacePath or remoteMarketplaceName', async () => {
  const app = fakeApp()
  const plugins = createCodexPlugins({ app })

  await plugins.install('sales@openai-curated-remote')
  await plugins.install('latex@openai-bundled')

  for (const call of app.calls.filter((c) => c.method === 'plugin/install')) {
    const keys = Object.keys(call.params)
    assert.equal(keys.filter((k) => k === 'marketplacePath' || k === 'remoteMarketplaceName').length, 1,
      `expected exactly one target key, got ${keys.join(', ')}`)
  }
})

// The uninstall half of the same rule. This one matters more than it looks: the server answers a
// wrong id with `{}` — indistinguishable from success — and removes nothing, so no amount of
// checking the reply would catch a regression here. The wire shape is the only observable.
test('a remote marketplace uninstalls by remotePluginId, a local one by plugin@marketplace', async () => {
  const app = fakeApp()
  const plugins = createCodexPlugins({ app })

  await plugins.uninstall('sales@openai-curated-remote')
  await plugins.uninstall('latex@openai-bundled')

  const removals = app.calls.filter((c) => c.method === 'plugin/uninstall')
  assert.deepEqual(removals[0].params, { pluginId: 'Plugin_af5b4b796b588191b3f2c610aa093799' })
  assert.deepEqual(removals[1].params, { pluginId: 'latex@openai-bundled' })
})

test('a remote plugin without a remotePluginId falls back rather than sending undefined', async () => {
  const app = fakeApp([{
    name: 'openai-curated-remote',
    path: null,
    plugins: [{
      id: 'bare@openai-curated-remote',
      name: 'bare',
      installed: false,
      mustShowInstallationInterstitial: false,
    }],
  }])
  const plugins = createCodexPlugins({ app })

  await plugins.install('bare@openai-curated-remote')
  await plugins.uninstall('bare@openai-curated-remote')

  assert.equal(app.calls.find((c) => c.method === 'plugin/install').params.pluginName, 'bare')
  assert.equal(app.calls.find((c) => c.method === 'plugin/uninstall').params.pluginId,
    'bare@openai-curated-remote')
})

test('acting on something no marketplace offers fails before it reaches the server', async () => {
  const app = fakeApp()
  const plugins = createCodexPlugins({ app })

  await assert.rejects(() => plugins.install('nope@openai-curated-remote'), /No plugin "nope@/)
  await assert.rejects(() => plugins.uninstall('nope@openai-curated-remote'), /No plugin "nope@/)
  assert.equal(app.calls.filter((c) => c.method === 'plugin/install').length, 0)
  assert.equal(app.calls.filter((c) => c.method === 'plugin/uninstall').length, 0)
})

test('a remote installation interstitial must be accepted before install', async () => {
  const app = fakeApp([{
    name: 'openai-curated-remote',
    path: null,
    plugins: [{
      id: 'review@openai-curated-remote',
      name: 'review',
      remotePluginId: 'Plugin_review',
      mustShowInstallationInterstitial: true,
    }],
  }])
  const plugins = createCodexPlugins({ app })

  await assert.rejects(
    () => plugins.install('review@openai-curated-remote'),
    /requires confirmation in Mechanician/,
  )
  await assert.rejects(
    () => plugins.install('review@openai-curated-remote', {
      installationInterstitialAccepted: 'yes',
    }),
    /requires confirmation in Mechanician/,
  )
  assert.equal(app.calls.filter((call) => call.method === 'plugin/install').length, 0)

  await plugins.install('review@openai-curated-remote', {
    installationInterstitialAccepted: true,
  })
  assert.equal(app.calls.filter((call) => call.method === 'plugin/install').length, 1)
})

test('a missing remote installation policy fails closed even after acceptance', async () => {
  const app = fakeApp([{
    name: 'openai-curated-remote',
    path: null,
    plugins: [{
      id: 'unknown@openai-curated-remote',
      name: 'unknown',
      remotePluginId: 'Plugin_unknown',
    }],
  }])
  const plugins = createCodexPlugins({ app })

  await assert.rejects(
    () => plugins.install('unknown@openai-curated-remote', {
      installationInterstitialAccepted: true,
    }),
    /could not verify the installation policy/,
  )
  assert.equal(app.calls.filter((call) => call.method === 'plugin/install').length, 0)
})

test('a local plugin needs no remote installation policy', async () => {
  const app = fakeApp([{
    name: 'local',
    path: '/tmp/local/marketplace.json',
    plugins: [{ id: 'local@marketplace', name: 'local' }],
  }])

  await createCodexPlugins({ app }).install('local@marketplace')

  assert.equal(app.calls.filter((call) => call.method === 'plugin/install').length, 1)
})

test('local art comes from the on-disk logo path, remote art from logoUrl', async () => {
  // The two halves of the catalog are exact opposites here: remote plugins set `logoUrl` and leave
  // `logo` null; local ones do the reverse. Reading only `logoUrl` rendered every bundled plugin as
  // a blank monogram despite each shipping a logo.
  const app = fakeApp([{
    name: 'openai-bundled',
    path: '/tmp/bundled/marketplace.json',
    plugins: [
      {
        // `latex`, not `computer-use`: the latter is gated by codex-plugin-viability (it needs a
        // runtime service the ChatGPT app installs) and would never reach the app to be rendered.
        id: 'latex@openai-bundled',
        name: 'latex',
        // A real path shape from the shipped bundle — the space is why this must be percent-encoded.
        interface: { displayName: 'LaTeX', logo: '/tmp/Codex Computer Use.app/logo.png' },
      },
      {
        id: 'relative@openai-bundled',
        name: 'relative',
        interface: { displayName: 'Relative', logo: 'assets/logo.png' },
      },
    ],
  }])

  const state = await createCodexPlugins({ app }).state()

  const byId = Object.fromEntries(state.plugins.map((p) => [p.pluginId, p]))
  assert.equal(byId['latex@openai-bundled'].logoUrl,
    'file:///tmp/Codex%20Computer%20Use.app/logo.png')
  // A relative path is not something the app can resolve, so it must degrade to the monogram
  // rather than emit a URL that silently fails to load.
  assert.equal(byId['relative@openai-bundled'].logoUrl, null)
})

test('a marketplace we register on the user\'s behalf is flagged, so the UI can withhold Remove', async () => {
  // We re-register these on every launch, so offering Remove would be offering a button that
  // silently undoes itself.
  const state = await createCodexPlugins({
    app: fakeApp(), bundledNames: ['openai-bundled'],
  }).state()

  const byName = Object.fromEntries(state.marketplaces.map((m) => [m.name, m]))
  assert.equal(byName['openai-bundled'].bundled, true)
  assert.equal(byName['openai-curated-remote'].bundled, false)
})

test('state flattens marketplaces and carries the art the Claude feed does not have', async () => {
  const plugins = createCodexPlugins({ app: fakeApp() })

  const state = await plugins.state()

  assert.deepEqual(state.marketplaces, [
    { name: 'openai-bundled', path: '/tmp/bundled/marketplace.json', remote: false, bundled: false, count: 1 },
    { name: 'openai-curated-remote', path: null, remote: true, bundled: false, count: 1 },
  ])
  const sales = state.plugins.find((p) => p.pluginId === 'sales@openai-curated-remote')
  assert.equal(sales.name, 'Sales')
  assert.equal(sales.developerName, 'OpenAI')
  assert.equal(sales.category, 'Business & Operations')
  assert.equal(sales.logoUrl, 'https://files.openai.com/logo.png')
  assert.equal(sales.marketplaceName, 'openai-curated-remote')
  assert.equal(sales.remote, true)
  assert.equal(sales.mustShowInstallationInterstitial, false)
  const latex = state.plugins.find((p) => p.pluginId === 'latex@openai-bundled')
  assert.equal(latex.remote, false)
  assert.equal(latex.mustShowInstallationInterstitial, null)
})

test('state preserves every remote installation-interstitial policy value', async () => {
  const plugin = (name, requirement) => ({
    id: `${name}@remote`,
    name,
    ...(requirement === undefined ? {} : { mustShowInstallationInterstitial: requirement }),
  })
  const state = await createCodexPlugins({
    app: fakeApp([{
      name: 'remote',
      path: null,
      plugins: [plugin('review', true), plugin('direct', false), plugin('unknown')],
    }]),
  }).state()

  const policies = Object.fromEntries(
    state.plugins.map((entry) => [entry.name, entry.mustShowInstallationInterstitial]),
  )
  assert.deepEqual(policies, { review: true, direct: false, unknown: null })
})

test('every command says Codex is not running rather than throwing an opaque error', async () => {
  const plugins = createCodexPlugins({ app: null })

  for (const run of [
    () => plugins.state(),
    () => plugins.install('sales@openai-curated-remote'),
    () => plugins.uninstall('sales@openai-curated-remote'),
    () => plugins.addMarketplace('owner/repo'),
    () => plugins.removeMarketplace('openai-bundled'),
    () => plugins.upgradeMarketplace('openai-bundled'),
  ]) {
    await assert.rejects(run, /Codex is not running/)
  }
})
