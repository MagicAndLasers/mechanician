// Claude plugin marketplaces, driven through the bundled `claude` binary.
//
// The binary is the API. Writing `extraKnownMarketplaces` into settings.json was measured NOT to
// install — zero `plugin_install` events, `init.plugins: []` — because that key declares a
// marketplace to a repository rather than driving installation. The CLI is what wrote every record
// in ~/.claude/plugins, so it is what we drive; agentd already spawns this same binary for auth.
//
// Verified shapes (2026-07-25, live, against a scratch CLAUDE_CONFIG_DIR):
//   plugin marketplace list --json  -> [{ name, source, repo, installLocation }]
//   plugin list --json              -> [{ id, version, scope, enabled, installPath,
//                                         installedAt, lastUpdated, mcpServers }]
//   plugin list --available --json  -> { installed: [...],
//                                        available: [{ pluginId, name, description,
//                                                      marketplaceName, source }] }
//   plugin marketplace add <src>    -> clones, validates, writes known_marketplaces.json
//   plugin install <id>@<market>    -> installs; the engine then reports it in init.plugins and
//                                      its skills appear namespaced as `plugin:skill`
//
// NOTE the id convention, which is the provider's and therefore ours: `plugin@marketplace`.

import { execFile } from 'node:child_process'
import fs from 'node:fs'
import path from 'node:path'
import { promisify } from 'node:util'

const run = promisify(execFile)

/// The CLI's browse feed is thinner than the data it was built from. `plugin list --available
/// --json` returns 7 fields; the marketplace manifest the CLI itself cloned carries 13, including
/// the three that answer "should I install this?" — `category` (95% of entries), `homepage` (94%)
/// and `author` (69%). None of them survive the CLI.
///
/// So read the manifest directly. It is already on disk — `marketplace list --json` hands us
/// `installLocation` — which makes this a synchronous file read with no network and no second CLI
/// call, joined onto the CLI's list by plugin name.
///
/// This is also where a long-standing wrong belief gets corrected: two code comments asserted that
/// Anthropic's feed has "no icon, category or author". No icon is true — there is genuinely no icon
/// field anywhere in the schema, which is why these cards stay text-only while the Codex ones carry
/// art. Category and author were simply being left on the floor.
function readMarketplaceManifest(installLocation) {
  if (!installLocation) return new Map()
  try {
    const manifest = JSON.parse(fs.readFileSync(
      path.join(installLocation, '.claude-plugin', 'marketplace.json'), 'utf8'))
    const byName = new Map()
    for (const entry of manifest?.plugins || []) {
      if (typeof entry?.name === 'string') byName.set(entry.name, entry)
    }
    return byName
  } catch {
    // A marketplace whose manifest we cannot read still browses fine on the CLI's seven fields.
    // Enrichment is additive; never let it break the listing.
    return new Map()
  }
}

/// What a plugin actually CONTAINS, from the catalog cache the CLI writes beside the marketplaces.
///
/// This is the answer to "what am I installing?", and nothing else in the pipeline has it: the
/// browse feed lists names and descriptions, and `claude plugin details` works only on plugins you
/// have ALREADY installed — useless for deciding. The cache carries the component inventory
/// (commands, agents, skills, hooks, MCP servers, LSP servers, each by name) plus what the plugin
/// costs you in context, for 255 of the 273 catalog entries, pre-install.
///
/// Keyed by `plugin@marketplace`, so the same lookup serves both the available list and the
/// installed one. Best-effort throughout: the file appears as a side effect of the catalog command
/// and can be stale or absent, and a missing inventory must never break a listing.
function readCatalogCache(installLocation) {
  if (!installLocation) return new Map()
  try {
    // <config>/plugins/marketplaces/<name> → <config>/plugins/plugin-catalog-cache.json
    const pluginsDirectory = path.dirname(path.dirname(installLocation))
    const cache = JSON.parse(fs.readFileSync(
      path.join(pluginsDirectory, 'plugin-catalog-cache.json'), 'utf8'))
    const byId = new Map()
    for (const [id, entry] of Object.entries(cache?.catalog?.plugins || {})) {
      byId.set(id, entry)
    }
    return byId
  } catch {
    return new Map()
  }
}

/// Component names only. The cache carries per-component character costs too, but a card needs to
/// say "3 skills, 1 MCP server" and name them — the byte accounting belongs to `tokens`.
function componentSummary(entry) {
  const components = entry?.components
  if (!components) return null
  const names = (list) => (Array.isArray(list) ? list : [])
    .map((item) => (typeof item === 'string' ? item : item?.name))
    .filter((name) => typeof name === 'string' && name)
  return {
    commands: names(components.commands),
    agents: names(components.agents),
    skills: names(components.skills),
    hooks: names(components.hooks),
    mcpServers: names(components.mcpServers),
    lspServers: names(components.lspServers),
  }
}

/// What it costs to have installed, in tokens, for whichever model the cache priced.
///
/// `always_on` is the part you pay on EVERY turn just for having it enabled; `on_invoke` is what it
/// costs when actually used. That distinction is the whole point — a plugin with a large always_on
/// is a permanent tax on the context window, and nothing else in either provider's UI shows it.
function tokenCost(entry) {
  const models = entry?.tokens
  if (!models || typeof models !== 'object') return null
  const [model, cost] = Object.entries(models)[0] || []
  if (!model || !cost) return null
  return {
    model,
    alwaysOn: Number(cost.always_on) || 0,
    onInvoke: Number(cost.on_invoke) || 0,
  }
}

/// An author is `{ name, url?, email? }` in the manifest but occasionally a bare string. Normalise,
/// because a card that renders `[object Object]` is worse than one that renders nothing.
function authorName(author) {
  if (typeof author === 'string') return author
  if (author && typeof author.name === 'string') return author.name
  return null
}

function authorURL(author) {
  if (author && typeof author.url === 'string') return author.url
  return null
}

/// Marketplace clones can be large repositories; `plugin marketplace add` clones with its own
/// 120s internal budget, so ours has to exceed it or we would kill a healthy clone.
const CLONE_TIMEOUT_MS = 180_000
const QUERY_TIMEOUT_MS = 30_000

/**
 * @param {object} deps
 * @param {string} deps.executable  the bundled `claude` binary
 * @param {NodeJS.ProcessEnv} deps.env  child environment (CLAUDE_CONFIG_DIR lives here)
 */
export function createClaudePlugins({ executable, env, exec = run }) {
  async function cli(args, { timeout = QUERY_TIMEOUT_MS } = {}) {
    if (!executable) throw new Error('The Claude command line could not be located.')
    const { stdout } = await exec(executable, args, { env, timeout, maxBuffer: 32 * 1024 * 1024 })
    return stdout
  }

  async function json(args, options) {
    const out = await cli(args, options)
    const text = String(out).trim()
    if (!text) return null
    try { return JSON.parse(text) } catch {
      // The CLI prints progress to stdout before the payload on some paths. Recover the JSON
      // rather than failing a working command over a leading log line.
      const start = text.search(/[[{]/)
      if (start < 0) throw new Error('The plugin command returned no JSON.')
      return JSON.parse(text.slice(start))
    }
  }

  return {
    /** Configured marketplaces. */
    async marketplaces() {
      const list = await json(['plugin', 'marketplace', 'list', '--json'])
      return Array.isArray(list) ? list : []
    },

    /**
     * Everything on offer, plus what is already installed — one call, because the CLI returns
     * both and asking twice would let them disagree.
     *
     * `available` is then enriched from each marketplace's on-disk manifest. Pass the marketplace
     * list in rather than fetching it again: the caller already has it, and two separate reads
     * could describe two different sets of marketplaces.
     */
    async catalog(marketplaces = []) {
      const data = await json(['plugin', 'list', '--available', '--json'])
      const manifests = new Map(
        marketplaces.map((m) => [m.name, readMarketplaceManifest(m.installLocation)]))
      // One cache serves every marketplace, so read it once from whichever install location we have.
      const cache = readCatalogCache(marketplaces.find((m) => m.installLocation)?.installLocation)

      /// The same enrichment for a browse entry and an installed one. An installed plugin needs its
      /// inventory MORE than an uninstalled one, not less — "what did I actually put in here, and
      /// what is it costing me every turn" is a question you ask after the fact.
      const enrich = (row, id) => {
        const entry = cache.get(id)
        if (!entry) return row
        // The cache also embeds the plugin's marketplace entry. That matters most for INSTALLED
        // plugins: the CLI omits them from `available` (272 of 273 on a machine with one installed),
        // so a lookup against the browse list can find nothing and the card comes back bare. Reading
        // description, category, author and homepage from here makes an installed card as complete
        // as an uninstalled one, which is the whole point of having one.
        const market = entry.marketplace_entry || {}
        return {
          ...row,
          components: componentSummary(entry),
          tokenCost: tokenCost(entry),
          lastUpdated: typeof entry.last_updated === 'string' ? entry.last_updated : null,
          installCount: typeof entry.unique_installs === 'number'
            ? entry.unique_installs : row.installCount ?? null,
          description: row.description || (typeof market.description === 'string' ? market.description : ''),
          category: row.category ?? (typeof market.category === 'string' ? market.category : null),
          homepage: row.homepage ?? (typeof market.homepage === 'string' ? market.homepage : null),
          authorName: row.authorName ?? authorName(market.author),
          authorURL: row.authorURL ?? authorURL(market.author),
        }
      }

      const installed = (Array.isArray(data?.installed) ? data.installed : [])
        .map((row) => enrich(row, row.id))
      const available = (Array.isArray(data?.available) ? data.available : []).map((plugin) => {
        const withComponents = enrich(plugin, plugin.pluginId)
        const entry = manifests.get(plugin.marketplaceName)?.get(plugin.name)
        if (!entry) return withComponents
        return {
          ...withComponents,
          // `displayName` is what the author wants it called — "Convex", not "convex".
          displayName: typeof entry.displayName === 'string' ? entry.displayName : null,
          category: typeof entry.category === 'string' ? entry.category : null,
          homepage: typeof entry.homepage === 'string' ? entry.homepage : null,
          authorName: authorName(entry.author),
          authorURL: authorURL(entry.author),
          // Present in the schema but nearly empty in practice — 1 of 273 for keywords, 3 for
          // tags. Carried because they cost nothing; NOT a browse axis. Category is.
          keywords: Array.isArray(entry.keywords) ? entry.keywords : [],
          license: typeof entry.license === 'string' ? entry.license : null,
        }
      })
      return { installed, available }
    },

    async installed() {
      const list = await json(['plugin', 'list', '--json'])
      return Array.isArray(list) ? list : []
    },

    /** `source` is a URL, a path, or `owner/repo`. */
    async addMarketplace(source) {
      await cli(['plugin', 'marketplace', 'add', source], { timeout: CLONE_TIMEOUT_MS })
    },

    async removeMarketplace(name) {
      await cli(['plugin', 'marketplace', 'remove', name])
    },

    async updateMarketplace(name) {
      await cli(['plugin', 'marketplace', 'update', ...(name ? [name] : [])],
        { timeout: CLONE_TIMEOUT_MS })
    },

    /** `id` is `plugin@marketplace` — the provider's own identity format. */
    async install(id) {
      await cli(['plugin', 'install', id], { timeout: CLONE_TIMEOUT_MS })
    },

    /// Reversible: the plugin stays on disk and can be re-enabled without re-cloning.
    async disable(id) {
      await cli(['plugin', 'disable', id])
    },

    async enable(id) {
      await cli(['plugin', 'enable', id])
    },

    /// Actually remove it. `claude plugin uninstall|remove <plugin>` is real — an earlier comment
    /// here claimed the CLI offered no removal verb, which was simply wrong and left the app with
    /// Disable as its only exit. `--keep-data` is deliberately NOT passed: a user asking to
    /// uninstall means it, and a stale data directory silently retained is a surprise.
    async uninstall(id) {
      await cli(['plugin', 'uninstall', id], { timeout: CLONE_TIMEOUT_MS })
    },

    async update(id) {
      await cli(['plugin', 'update', id], { timeout: CLONE_TIMEOUT_MS })
    },
  }
}

/// Human-readable failure. The CLI writes its real reason to stderr and exits non-zero; surfacing
/// the exit code alone would leave the user with nothing to act on.
export function describePluginError(error) {
  const detail = String(error?.stderr || error?.message || error || '').trim()
  if (/timed? ?out|ETIMEDOUT/i.test(detail)) {
    return 'The plugin command timed out. A large marketplace can take a while to clone.'
  }
  if (/not found|no such|unknown marketplace/i.test(detail)) return detail
  return detail || 'The plugin command failed.'
}
