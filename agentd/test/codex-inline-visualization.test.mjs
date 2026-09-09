import assert from 'node:assert/strict'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import test from 'node:test'

import {
  extractInlineVisualizations, resolveFragment, wrapFragment,
} from '../src/codex-inline-visualization.mjs'

const PLACEHOLDER = '<!--__INLINE_VISUALIZATION_FRAGMENT__-->'

/// A machine with the visualize plugin installed: the skill's assets under CODEX_HOME's plugin
/// cache, and a fragment in the thread-scoped visualization directory the plugin writes to.
function machine({ fragment = '<div id="v">hello</div>', file = 'my-chart.html', day = '2026/07/25' } = {}) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'codex-vis-'))
  const cwd = path.join(root, 'workspace')
  const codexHome = path.join(root, 'codex')
  const skill = path.join(codexHome, 'plugins', 'cache', 'openai-bundled', 'visualize', '1.0.14',
                          'skills', 'visualize', 'assets')
  fs.mkdirSync(skill, { recursive: true })
  fs.writeFileSync(path.join(skill, 'visualize.html'), `<main>${PLACEHOLDER}</main>`)
  fs.writeFileSync(path.join(skill, 'visualize.css'), '.card{color:red}')
  const visDirectory = path.join(cwd, '.codex', 'visualizations', day, 'thread-abc')
  fs.mkdirSync(visDirectory, { recursive: true })
  if (fragment !== null) fs.writeFileSync(path.join(visDirectory, file), fragment)
  return { root, cwd, codexHome, home: root, fragmentPath: path.join(visDirectory, file) }
}

const run = (text, m) =>
  extractInlineVisualizations(text, { cwd: m.cwd, codexHome: m.codexHome, home: m.home })

test('a directive becomes an artifact and leaves the prose behind', () => {
  const m = machine()
  const result = run('Here is the shape of it.\n\n::codex-inline-vis{file="my-chart.html"}\n', m)

  assert.equal(result.artifacts.length, 1)
  assert.equal(result.artifacts[0].type, 'html')
  assert.equal(result.artifacts[0].title, 'My Chart')
  assert.match(result.artifacts[0].source, /<div id="v">hello<\/div>/)
  // The directive itself must not survive into the transcript.
  assert.ok(!result.text.includes('codex-inline-vis'))
  assert.match(result.text, /Here is the shape of it\./)
})

test("the plugin's own kit and stylesheet are used, not a private copy", () => {
  const m = machine()
  const [artifact] = run('::codex-inline-vis{file="my-chart.html"}', m).artifacts

  // The fragment is spliced into the plugin's kit at its placeholder…
  assert.match(artifact.source, /<main><div id="v">hello<\/div><\/main>/)
  // …and the plugin's stylesheet is inlined, so a plugin update changes the rendering.
  assert.match(artifact.source, /\.card\{color:red\}/)
})

test('the CSP is the wrapper, so a model-authored fragment cannot reach arbitrary origins', () => {
  const m = machine()
  const [artifact] = run('::codex-inline-vis{file="my-chart.html"}', m).artifacts

  assert.match(artifact.source, /Content-Security-Policy/)
  assert.match(artifact.source, /default-src &#39;none&#39;/)
  assert.match(artifact.source, /https:\/\/cdnjs\.cloudflare\.com/)
  // Nothing may be fetched from an origin outside the plugin's allowlist.
  assert.ok(!artifact.source.includes('connect-src *'))
  assert.match(artifact.source, /connect-src blob: data:/)
})

test('a directive whose fragment is missing is LEFT IN PLACE, not silently deleted', () => {
  // Deleting it would leave a reply referring to a visual that never appears. The raw directive at
  // least shows that something was meant to be there.
  const m = machine({ fragment: null })
  const result = run('::codex-inline-vis{file="my-chart.html"}', m)

  assert.equal(result.artifacts.length, 0)
  assert.match(result.text, /codex-inline-vis/)
})

test('several visuals in one message each become their own artifact', () => {
  const m = machine()
  fs.writeFileSync(path.join(path.dirname(m.fragmentPath), 'second.html'), '<p id="b">two</p>')
  const result = run(
    'First:\n::codex-inline-vis{file="my-chart.html"}\nThen:\n::codex-inline-vis{file="second.html"}\n', m)

  assert.deepEqual(result.artifacts.map((a) => a.title), ['My Chart', 'Second'])
  assert.ok(!result.text.includes('codex-inline-vis'))
})

test('a path traversal in the directive is refused rather than resolved', () => {
  const m = machine()
  for (const file of ['../secrets.html', 'a/b.html', '..\\windows.html']) {
    assert.equal(resolveFragment(file, { cwd: m.cwd, codexHome: m.codexHome }), null, file)
  }
})

test('the newest fragment wins when the same name exists on two days', () => {
  const m = machine({ day: '2026/07/24' })
  const newer = path.join(m.cwd, '.codex', 'visualizations', '2026/07/25', 'thread-abc')
  fs.mkdirSync(newer, { recursive: true })
  const newest = path.join(newer, 'my-chart.html')
  fs.writeFileSync(newest, '<div id="new">newer</div>')
  fs.utimesSync(newest, new Date(2030, 0, 1), new Date(2030, 0, 1))

  assert.equal(resolveFragment('my-chart.html', { cwd: m.cwd, codexHome: m.codexHome }), newest)
})

test('text with no directive is returned untouched and costs nothing', () => {
  const m = machine()
  const text = 'An ordinary reply about ::something:: else.'
  assert.deepEqual(run(text, m), { text, artifacts: [] })
})

test('a directive is only honoured on its own line', () => {
  // Inline in prose it is being discussed, not emitted — the SKILL.md requires its own line.
  const m = machine()
  const text = 'Write `::codex-inline-vis{file="my-chart.html"}` to place the visual.'
  assert.equal(run(text, m).artifacts.length, 0)
})

test('wrapFragment escapes the title rather than injecting it', () => {
  const html = wrapFragment('<p>x</p>', { kit: PLACEHOLDER, css: '' }, '</title><script>evil()</script>')
  assert.ok(!html.includes('<script>evil()</script>'))
  assert.match(html, /&lt;\/title&gt;/)
})
