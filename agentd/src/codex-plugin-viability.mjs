// Which of Codex's LOCAL plugins actually function inside Mechanician.
//
// FR-110 registered the two bundled marketplaces, which made thirteen plugins visible. Measured
// per-plugin — by reading each plugin directory, its .mcp.json, and the config the ChatGPT desktop
// app writes that we do not have — only some of them work here. The rest install successfully and
// then do nothing, which is the worst failure mode available: the app vouching for something it has
// not checked.
//
// So they are hidden. Not disabled with an explanation, not badged — hidden, because a plugin you
// cannot use is not a choice you should have to evaluate.
//
// This list is deliberately NARROW and keyed on `plugin@marketplace`. It names only plugins proven
// to need the ChatGPT app; anything unlisted stays visible, so an OpenAI update that adds a plugin
// surfaces it rather than silently swallowing it.

/// Plugins that cannot work without the ChatGPT desktop app, with the specific reason.
///
/// The reason matters, because it says whether the entry is permanent. Both that remain are blocked
/// on a piece of the ChatGPT app itself — a browser backend, a Chrome extension — not on anything we
/// failed to build.
///   browser            — targets ChatGPT's own in-app browser. Unwinnable; there is no backend for
///                        us to point it at.
///   chrome             — needs a 12-variable [mcp_servers.node_repl] block, the ChatGPT Chrome
///                        extension, and its native-messaging host. Replicable but expensive, and
///                        Mechanician already ships Playwright MCP for the same job.
///
/// THREE PLUGINS CAME OFF THIS LIST, each for a different reason, and the reasons are worth keeping
/// because they are the difference between "cannot work" and "we had not done the work":
///   visualize          — needed a host that honours its `::codex-inline-vis` directive.
///                        Mechanician now does (codex-inline-visualization.mjs).
///   sites              — its `choose_site_design` tool needs an `openai/form` elicitation, which
///                        agentd used to decline outright. Elicitation is now answered by the user
///                        (mcp-elicitation.mjs, FR-116). Publishing a site still needs the
///                        account-side Sites connector, so a local build works and publishing may
///                        not — but that is the server telling the user something, not us hiding
///                        the plugin.
///   computer-use       — listed as UNKNOWN on the theory that codex copying a signed `.app` into
///   record-and-replay   plugins/cache might break it. MEASURED, and it does not: the copy passes
///                        `codesign -v --deep --strict`, Gatekeeper accepts it as a notarized
///                        OpenAI Developer ID, and both MCP servers start from the copy and list
///                        their tools (computer-use 10, record-and-replay 3). Their `.mcp.json`
///                        uses a RELATIVE command with `cwd: "."`, so nothing outside the plugin
///                        directory is referenced — the ~/.codex service the strings mention is
///                        the ChatGPT app's own copy, not a dependency of ours. Hiding a working
///                        plugin because we had not checked was the wrong call.
///
/// `documents` and `pdf` were never listed but were equally broken, for a third reason: the runtime
/// binaries they shell out to were missing from PATH (codex-runtime-path.mjs).
export const REQUIRES_CHATGPT_APP = new Map([
  ['browser@openai-bundled', 'targets the ChatGPT app’s own browser'],
  ['chrome@openai-bundled', 'needs the ChatGPT Chrome extension and its native-messaging host'],
])

/// True when a plugin should not be offered at all.
///
/// Only ever hides something ALREADY INSTALLED if it is also unusable — an installed-but-hidden
/// plugin would be unremovable through the UI. In practice none of these installs cleanly, but the
/// guard makes that explicit rather than accidental.
export function isUnsupported(plugin) {
  return REQUIRES_CHATGPT_APP.has(plugin?.pluginId) && plugin?.installed !== true
}

export function unsupportedReason(pluginId) {
  return REQUIRES_CHATGPT_APP.get(pluginId) || null
}
