// The `visualize` plugin's inline-visualization contract, implemented for Mechanician.
//
// The plugin writes an HTML FRAGMENT to a thread-scoped directory and then emits, on its own line:
//
//     ::codex-inline-vis{file="<title>.html"}
//
// A host that does not understand that directive shows the user a line of raw markup instead of the
// visual, which is why the plugin was one of the six that installed and did nothing here.
//
// The wrapper is the plugin's own, not ours: `assets/visualize.html` is a kit with a
// `<!--__INLINE_VISUALIZATION_FRAGMENT__-->` placeholder, `assets/visualize.css` styles it, and
// `scripts/render.py` defines the CSP. Reading those from the installed plugin rather than
// reimplementing them means a plugin update changes the rendering, as it should — and means we are
// not maintaining a private copy of OpenAI's stylesheet.
//
// The result becomes a normal Mechanician ARTIFACT. That is deliberate: artifacts already have a
// preview pane, a panel, export and a pop-out window, and "the visual output of a turn" is exactly
// what that surface is for. Inventing a second inline renderer would have been the larger change and
// the worse one.

import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'

const FRAGMENT_PLACEHOLDER = '<!--__INLINE_VISUALIZATION_FRAGMENT__-->'
const DIRECTIVE = /^[ \t]*::codex-inline-vis\{file="([^"]+)"\}[ \t]*$/gm

/// Where the plugin's skill directory lives once installed. Codex copies a plugin into
/// `$CODEX_HOME/plugins/cache/<marketplace>/<plugin>/<version>/`, and the bundled source stays
/// readable in the ChatGPT app — check the installed copy first so an upgraded plugin wins.
function skillDirectories(codexHome, home) {
  const roots = []
  const cache = path.join(codexHome, 'plugins', 'cache')
  try {
    for (const marketplace of fs.readdirSync(cache)) {
      const pluginRoot = path.join(cache, marketplace, 'visualize')
      for (const version of fs.readdirSync(pluginRoot)) {
        roots.push(path.join(pluginRoot, version, 'skills', 'visualize'))
      }
    }
  } catch { /* not installed from a marketplace; fall through */ }
  for (const applications of ['/Applications', path.join(home, 'Applications')]) {
    roots.push(path.join(applications, 'ChatGPT.app', 'Contents', 'Resources', 'plugins',
                         'openai-bundled', 'plugins', 'visualize', 'skills', 'visualize'))
  }
  return roots
}

function readSkillAssets(codexHome, home) {
  for (const directory of skillDirectories(codexHome, home)) {
    try {
      return {
        kit: fs.readFileSync(path.join(directory, 'assets', 'visualize.html'), 'utf8'),
        css: fs.readFileSync(path.join(directory, 'assets', 'visualize.css'), 'utf8'),
      }
    } catch { /* try the next candidate */ }
  }
  return null
}

/// The plugin's own CSP, transcribed from its `scripts/render.py`. Kept verbatim rather than
/// loosened: it is what makes an arbitrary model-authored fragment safe to run, and the allowlist is
/// the plugin's promise to its own authors about which CDNs will work.
const RESOURCE_SOURCES = [
  'blob:', 'data:',
  'https://cdnjs.cloudflare.com', 'https://cdn.jsdelivr.net', 'https://esm.sh',
  'https://fonts.bunny.net', 'https://fonts.googleapis.com', 'https://fonts.gstatic.com',
  'https://unpkg.com',
].join(' ')

const CSP = [
  "default-src 'none'",
  `script-src 'unsafe-inline' 'unsafe-eval' 'wasm-unsafe-eval' ${RESOURCE_SOURCES}`,
  `style-src 'unsafe-inline' ${RESOURCE_SOURCES}`,
  `img-src ${RESOURCE_SOURCES}`,
  `font-src ${RESOURCE_SOURCES}`,
  `media-src ${RESOURCE_SOURCES}`,
  "worker-src blob:",
  "connect-src blob: data:",
  "frame-src 'none'",
  "object-src 'none'",
  "base-uri 'none'",
  "form-action 'none'",
].join('; ')

function escapeHTML(text) {
  return String(text).replace(/[&<>"']/g, (c) => (
    { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]
  ))
}

export function wrapFragment(fragment, { kit, css }, title) {
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="referrer" content="no-referrer">
<meta http-equiv="Content-Security-Policy" content="${escapeHTML(CSP)}">
<title>${escapeHTML(title)}</title>
<style>${css}
html>body{padding:0}</style>
</head>
<body>
${kit.replace(FRAGMENT_PLACEHOLDER, fragment)}
</body>
</html>
`
}

/// Find the fragment the directive names.
///
/// The plugin writes into `.codex/visualizations/YYYY/MM/DD/<thread-id>/`, so the exact path depends
/// on the date and thread. Rather than reconstruct that — and be wrong at midnight, or when the
/// model picks a different writable root — search the visualization tree for the filename and take
/// the most recent match. The directive carries a bare filename by contract, so a traversal attempt
/// is refused outright rather than resolved.
export function resolveFragment(file, { cwd, codexHome }) {
  if (!file || file.includes('/') || file.includes('\\') || file.includes('..')) return null
  const roots = [
    path.join(cwd || '.', '.codex', 'visualizations'),
    path.join(codexHome, 'visualizations'),
  ]
  let best = null
  const visit = (directory, depth) => {
    if (depth > 6) return
    let entries = []
    try { entries = fs.readdirSync(directory, { withFileTypes: true }) } catch { return }
    for (const entry of entries) {
      const full = path.join(directory, entry.name)
      if (entry.isDirectory()) { visit(full, depth + 1); continue }
      if (entry.name !== file) continue
      try {
        const stat = fs.statSync(full)
        if (!best || stat.mtimeMs > best.mtimeMs) best = { path: full, mtimeMs: stat.mtimeMs }
      } catch { /* raced with a write; ignore */ }
    }
  }
  for (const root of roots) visit(root, 0)
  return best?.path || null
}

/**
 * Pull every inline-visualization directive out of a message.
 *
 * Returns the text with the directives REMOVED and one artifact per resolved visual. A directive
 * whose fragment cannot be found is left in place: silently deleting it would leave the user with a
 * reply that refers to a visual which never appears, and the raw directive at least shows that
 * something was meant to be there.
 */
export function extractInlineVisualizations(text, { cwd, codexHome, home = os.homedir() } = {}) {
  if (typeof text !== 'string' || !text.includes('::codex-inline-vis')) {
    return { text, artifacts: [] }
  }
  const assets = readSkillAssets(codexHome, home)
  const artifacts = []
  const cleaned = text.replace(DIRECTIVE, (directive, file) => {
    if (!assets) return directive
    const fragmentPath = resolveFragment(file, { cwd, codexHome })
    if (!fragmentPath) return directive
    let fragment
    try { fragment = fs.readFileSync(fragmentPath, 'utf8') } catch { return directive }
    const title = path.basename(file, '.html').replace(/-/g, ' ').replace(/\b\w/g, (c) => c.toUpperCase())
    artifacts.push({ type: 'html', title, source: wrapFragment(fragment, assets, title) })
    return ''
  })
  // Directives sit on their own line, so removing them leaves a blank line behind.
  return { text: cleaned.replace(/\n{3,}/g, '\n\n'), artifacts }
}
