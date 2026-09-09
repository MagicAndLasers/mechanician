// Codex plugin marketplaces, over the app-server's v2 plugin protocol.
//
// The mirror image of claude-plugins.mjs: same nouns (marketplace, plugin, `plugin@marketplace`),
// same screen, different transport. Codex is imperative JSON-RPC where Anthropic is a CLI, and
// agentd already owns both channels.
//
// Verified live (2026-07-25) against the shipped app-server. Parameter names come from the
// server's own validation errors, not from guesswork:
//   plugin/list        -> { marketplaces: [{ name, path, interface, plugins: [...] }] }
//   plugin/installed   -> same shape, installed only
//   plugin/install     -> { pluginName, + EXACTLY ONE of marketplacePath | remoteMarketplaceName }
//   plugin/uninstall   -> { pluginId }
//   marketplace/add    -> { source }  (owner/repo, a git URL, or a local marketplace path)
//   marketplace/remove -> { marketplaceName }
//
// A marketplace is either LOCAL (has `path`) or REMOTE (catalog only, `path` is null), and that
// split runs deeper than the "exactly one of" rule above: it also decides WHICH IDENTIFIER names the
// plugin. A local marketplace knows plugins by `name` (install) and `name@marketplace` (uninstall);
// a remote catalog knows them only by `remotePluginId` — for BOTH verbs. Get it wrong and the two
// verbs fail differently, which is what makes this worth spelling out:
//   * install rejects loudly — the server splices the id into `…/ps/plugins/<id>` and returns 404.
//   * uninstall fails SILENTLY — it returns `{}`, exactly like a success, and removes nothing.
// See serverPluginId(). There is no test that can catch the silent one from the outside, so the
// unit tests assert on the wire shape instead.

import { pathToFileURL } from 'node:url'

import { isUnsupported } from './codex-plugin-viability.mjs'

const INSTALL_TIMEOUT_MS = 180_000
const QUERY_TIMEOUT_MS = 30_000

/// Where a plugin's logo lives, as something the app can actually load.
///
/// The two halves of the catalog carry art differently and the difference is total: every remote
/// plugin sets `logoUrl` and leaves `logo` null; every LOCAL plugin does the exact reverse, putting
/// an absolute on-disk path in `logo`. Reading only `logoUrl` — which is what shipped — renders all
/// twelve bundled plugins as blank monograms despite each one shipping a logo.
///
/// `pathToFileURL` rather than string concatenation because these paths contain spaces (the
/// computer-use plugin ships a `Codex Computer Use.app`), and an unescaped space makes `URL(string:)`
/// return nil on the Swift side. A logo that is an SVG still falls back to the monogram, because
/// ImageIO does not decode SVG — that is the placeholder doing its job, not a missing case.
function artURL(ui) {
  if (ui.logoUrl || ui.logoUrlDark) return ui.logoUrl || ui.logoUrlDark
  const local = ui.logo || ui.logoDark
  if (typeof local !== 'string' || !local.startsWith('/')) return null
  try {
    return pathToFileURL(local).href
  } catch {
    return null
  }
}

export function createCodexPlugins({ app, bundledNames = [], mutateConfig = (work) => work() }) {
  /// Marketplaces Mechanician registers for you because they ship on this Mac (see
  /// codex-bundled-marketplaces.mjs). They must not offer Remove: we re-register them on the next
  /// launch, so the button would silently undo itself.
  const bundled = new Set(bundledNames)

  function requireApp() {
    if (!app) throw new Error('Codex is not running, so plugins are unavailable.')
    return app
  }

  async function listAll() {
    const result = await requireApp().request('plugin/list', {}, QUERY_TIMEOUT_MS)
    return Array.isArray(result?.marketplaces) ? result.marketplaces : []
  }

  /// Which key `plugin/install` needs depends on how the marketplace is backed: a local file has a
  /// path, a remote catalog has only a name. Sending both, or the wrong one, is rejected outright.
  function installTarget(marketplace) {
    return marketplace?.path
      ? { marketplacePath: marketplace.path }
      : { remoteMarketplaceName: marketplace?.name }
  }

  /// The identifier the server will accept for a plugin, which depends on where it came from.
  /// Remote plugins are addressed by `remotePluginId` for every verb; local ones by the name-shaped
  /// id the verb asks for. `fallback` is what a local marketplace uses, and what a remote plugin
  /// degrades to if the catalog ever omits `remotePluginId` — better a request the server rejects
  /// than one carrying `undefined`.
  function serverPluginId(marketplace, plugin, fallback) {
    if (marketplace?.path) return fallback
    return plugin.remotePluginId || fallback
  }

  /// Find the marketplace that offers a plugin, so a caller holding only a `plugin@marketplace` id
  /// can be turned into the identifier that verb actually needs.
  async function locate(pluginId) {
    const marketplaces = await listAll()
    const owner = marketplaces.find((m) => (m.plugins || []).some((p) => p.id === pluginId))
    const plugin = (owner?.plugins || []).find((p) => p.id === pluginId)
    if (!owner || !plugin) throw new Error(`No plugin "${pluginId}" is offered by any marketplace.`)
    return { owner, plugin }
  }

  return {
    /**
     * Marketplaces and their plugins, flattened into the shape the app renders. Codex returns
     * everything in one call, so there is no window where the tab set and its contents disagree.
     */
    async state() {
      const marketplaces = await listAll()
      const flatPlugins = []
      for (const marketplace of marketplaces) {
        for (const plugin of marketplace.plugins || []) {
          const ui = plugin.interface || {}
          flatPlugins.push({
            pluginId: plugin.id,
            name: ui.displayName || plugin.name,
            description: ui.shortDescription || '',
            marketplaceName: marketplace.name,
            installed: plugin.installed === true,
            enabled: plugin.enabled !== false,
            version: plugin.localVersion || plugin.version || null,
            // The art Anthropic's feed does not have. Passing it through is the whole reason the
            // two card designs differ.
            category: ui.category || null,
            developerName: ui.developerName || null,
            logoUrl: artURL(ui),
            // Everything below this line exists to answer "do I want this?" — the question a card
            // with a 27-character summary cannot answer. All of it was already arriving from the
            // server and being discarded here.
            //   longDescription   100% populated, median 408 chars
            //   privacyPolicyUrl   98.7%      termsOfServiceUrl  98.2%
            //   websiteUrl         96.3%      defaultPrompt      70.1%
            //   screenshotUrls     59.8%  (2,951 images, public, no auth)
            longDescription: ui.longDescription || null,
            websiteUrl: ui.websiteUrl || null,
            privacyPolicyUrl: ui.privacyPolicyUrl || null,
            termsOfServiceUrl: ui.termsOfServiceUrl || null,
            screenshotUrls: Array.isArray(ui.screenshotUrls) ? ui.screenshotUrls : [],
            // What it suggests you say to it — the clearest statement of what it is FOR.
            defaultPrompt: Array.isArray(ui.defaultPrompt) ? ui.defaultPrompt : [],
            // Only 5.8% carry these and the long tail is free-text sentences, so it is detail-view
            // material, never a facet.
            capabilities: Array.isArray(ui.capabilities) ? ui.capabilities : [],
            // Codex gates some entries; a card must not offer Install on something the policy
            // will refuse.
            availability: plugin.availability || 'AVAILABLE',
            installPolicy: plugin.installPolicy || 'AVAILABLE',
            // Remote policy decides whether the host must stop for an installation interstitial.
            // `null` is intentionally preserved: 0.146 uses it when the remote policy could not be
            // resolved, and treating that as `false` would silently turn fail-closed into install.
            mustShowInstallationInterstitial:
              typeof plugin.mustShowInstallationInterstitial === 'boolean'
                ? plugin.mustShowInstallationInterstitial : null,
            remote: !marketplace.path,
          })
        }
      }
      // Plugins that cannot work without the ChatGPT desktop app are dropped here rather than
      // rendered with a caveat: a plugin you cannot use is not a choice worth presenting. Filtering
      // at the source also keeps the marketplace tab counts honest — a tab reading 8 above a grid of
      // 3 would be its own small lie.
      const offered = flatPlugins.filter((plugin) => !isUnsupported(plugin))
      const offeredByMarketplace = new Map()
      for (const plugin of offered) {
        offeredByMarketplace.set(plugin.marketplaceName,
          (offeredByMarketplace.get(plugin.marketplaceName) || 0) + 1)
      }
      return {
        marketplaces: marketplaces.map((m) => ({
          name: m.name,
          // A remote catalog has no local path. Say which, because it changes what Refresh means.
          path: m.path || null,
          remote: !m.path,
          bundled: bundled.has(m.name),
          count: offeredByMarketplace.get(m.name) || 0,
        })),
        plugins: offered,
      }
    },

    async install(pluginId, { installationInterstitialAccepted = false } = {}) {
      const { owner, plugin } = await locate(pluginId)
      if (!owner.path) {
        if (typeof plugin.mustShowInstallationInterstitial !== 'boolean') {
          throw new Error(
            `Codex could not verify the installation policy for "${plugin.name}". `
            + 'Try again later.',
          )
        }
        if (plugin.mustShowInstallationInterstitial
          && installationInterstitialAccepted !== true) {
          throw new Error(`Installing "${plugin.name}" requires confirmation in Mechanician.`)
        }
      }
      await mutateConfig(() => requireApp().request('plugin/install', {
        // `pluginName` is the field's name, not its meaning — remote catalogs want the remote id.
        pluginName: serverPluginId(owner, plugin, plugin.name),
        ...installTarget(owner),
      }, INSTALL_TIMEOUT_MS))
    },

    async uninstall(pluginId) {
      const { owner, plugin } = await locate(pluginId)
      await mutateConfig(() => requireApp().request('plugin/uninstall', {
        // Passing `plugin@marketplace` for a remote plugin returns `{}` and removes nothing, so the
        // caller cannot detect the miss. Resolve the id before asking rather than trusting the reply.
        pluginId: serverPluginId(owner, plugin, pluginId),
      }, INSTALL_TIMEOUT_MS))
    },

    async addMarketplace(source) {
      await mutateConfig(() => requireApp().request(
        'marketplace/add', { source }, INSTALL_TIMEOUT_MS))
    },

    async removeMarketplace(marketplaceName) {
      await mutateConfig(() => requireApp().request(
        'marketplace/remove', { marketplaceName }, QUERY_TIMEOUT_MS))
    },

    async upgradeMarketplace(marketplaceName) {
      await mutateConfig(() => requireApp().request(
        'marketplace/upgrade', { marketplaceName }, INSTALL_TIMEOUT_MS))
    },
  }
}
