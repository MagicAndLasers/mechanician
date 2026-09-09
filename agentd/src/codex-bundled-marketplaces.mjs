// Register the LOCAL Codex marketplaces that ship on this Mac (FR-110).
//
// Codex discovers marketplaces from exactly one place: the `[marketplaces.*]` tables in
// $CODEX_HOME/config.toml. There is no directory auto-discovery, no first-run flag, no version
// marker and no sync RPC — measured against throwaway homes, including one where the bundled
// directory was present but unregistered (result: zero marketplaces).
//
// The ChatGPT desktop app writes those tables into ~/.codex/config.toml from its Electron layer,
// not from the codex binary. Mechanician spawns the app-server itself and keeps its own
// $CODEX_HOME, so that reconciler never runs for us — which is the whole of FR-110. Our Codex lane
// saw only the 2,216-entry remote catalog and none of the twelve LOCAL plugins already on disk:
// browser, computer-use, record-and-replay, sites, chrome, latex, visualize, deep-research, and the
// five runtime document plugins.
//
// The fix is to register the same source paths. No copying: the ChatGPT app's own copy is a 189 MB
// `ditto` of a directory we can read in place, and installing FROM that read-only source is
// verified to work (`latex` installed at 0.2.4 from /Applications in a scratch home).
//
// `marketplace/add` is preferred over writing config.toml ourselves. It makes codex own the table —
// including the `last_updated` key — and reload. Emitting these tables from our managed region
// instead would risk a SECOND `[marketplaces.openai-bundled]` if the user ever adds one through the
// Extensions UI, and a duplicate TOML table makes the whole file unparseable, taking the managed MCP
// servers and every project trust entry down with it.

import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'

const ADD_TIMEOUT_MS = 60_000
const LIST_TIMEOUT_MS = 30_000

/// Where a local marketplace can legitimately come from. All are read-only, all are written by
/// OpenAI's own software, and all are absent on a Mac without the ChatGPT desktop app — in which
/// case there is simply nothing to register and we say nothing.
///
/// `applications` is a parameter rather than a constant so tests can be hermetic; on a real machine
/// it is `/Applications`, which is absolute and would otherwise make every test read the developer's
/// own ChatGPT install.
function candidateRoots({ home, applications }) {
  const chatGPTPlugins = (base) =>
    path.join(base, 'ChatGPT.app', 'Contents', 'Resources', 'plugins')
  return [
    // The ChatGPT app bundle. Stable across app updates because the path is inside the bundle, and a
    // stale entry pointing at a deleted app is skipped by codex without an error.
    chatGPTPlugins(applications),
    chatGPTPlugins(path.join(home, 'Applications')),
    // The primary runtime the ChatGPT app downloads. Shared across every CODEX_HOME, so it is
    // already on disk for us; only the config entry was missing.
    path.join(home, '.cache', 'codex-runtimes', 'codex-primary-runtime', 'plugins'),
  ]
}

/// A directory is a marketplace only if it carries the manifest codex looks for. Take the NAME from
/// that manifest rather than from the directory: internal ChatGPT builds ship `openai-bundled-alpha`
/// under the same layout, and the name is what `plugin/list` reports back for the skip check.
function readMarketplace(directory) {
  const manifest = path.join(directory, '.agents', 'plugins', 'marketplace.json')
  try {
    const name = JSON.parse(fs.readFileSync(manifest, 'utf8'))?.name
    return typeof name === 'string' && name ? { name, source: directory } : null
  } catch {
    return null
  }
}

export function discoverBundledMarketplaces({
  home = os.homedir(), applications = '/Applications',
} = {}) {
  const found = new Map()
  for (const root of candidateRoots({ home, applications })) {
    let entries = []
    try {
      entries = fs.readdirSync(root, { withFileTypes: true })
    } catch {
      continue // No ChatGPT app, or no runtime downloaded. Nothing to register, and that is fine.
    }
    for (const entry of entries) {
      if (!entry.isDirectory()) continue
      const marketplace = readMarketplace(path.join(root, entry.name))
      // First root wins: /Applications before ~/Applications, so a system install is preferred over
      // a per-user copy of the same marketplace name.
      if (marketplace && !found.has(marketplace.name)) found.set(marketplace.name, marketplace)
    }
  }
  return [...found.values()]
}

/**
 * Register any local marketplace that this home does not already know about.
 *
 * Idempotent twice over: we skip names `plugin/list` already reports, and `marketplace/add` itself
 * answers `alreadyAdded` for one it has. Codex persists the table, so the common case after first
 * run is a single `plugin/list` and no writes.
 *
 * Never throws. This runs on the Codex lane's startup path, and a marketplace we could not register
 * must never be the reason a conversation fails to start.
 */
export async function ensureBundledMarketplaces({
  app, log = () => {}, discover, mutateConfig = (work) => work(),
} = {}) {
  if (!app) return { added: [], skipped: [], failed: [] }
  const candidates = (discover || discoverBundledMarketplaces)()
  if (!candidates.length) return { added: [], skipped: [], failed: [] }

  let known = new Set()
  try {
    const listed = await app.request('plugin/list', {}, LIST_TIMEOUT_MS)
    known = new Set((listed?.marketplaces || []).map((m) => m.name))
  } catch (error) {
    // Without a listing we cannot tell new from known. `marketplace/add` is safe to repeat, so
    // carry on rather than skipping the registration entirely.
    log(`[codex] could not list marketplaces before registering bundled ones: ${error?.message || error}`)
  }

  const added = []
  const skipped = []
  const failed = []
  for (const marketplace of candidates) {
    if (known.has(marketplace.name)) { skipped.push(marketplace.name); continue }
    try {
      const result = await mutateConfig(() => app.request(
        'marketplace/add', { source: marketplace.source }, ADD_TIMEOUT_MS))
      if (result?.alreadyAdded) skipped.push(marketplace.name)
      else added.push(marketplace.name)
    } catch (error) {
      failed.push({ name: marketplace.name, message: String(error?.message || error) })
      log(`[codex] could not register bundled marketplace "${marketplace.name}": ${error?.message || error}`)
    }
  }
  if (added.length) log(`[codex] registered local marketplace(s): ${added.join(', ')}`)
  return { added, skipped, failed }
}
