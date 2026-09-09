import assert from 'node:assert/strict'
import test from 'node:test'

import {
  BLOCK_BEGIN,
  BLOCK_END,
  configuredServerNames,
  foreignServerNames,
  hasForeignShellEnvironmentPolicy,
  managedCodexExclusions,
  mergeManagedCodexConfig,
  renderManagedCodexConfig,
} from '../src/codex-config-file.mjs'

const CODEX_OWNED = [
  '[projects."/Users/someone/code"]',
  'trust_level = "trusted"',
  '',
  'model = "gpt-5.6"',
  '',
].join('\n')

test('renders stdio and remote servers in Codex key form', () => {
  const block = renderManagedCodexConfig({
    git: { command: '/usr/bin/git-mcp', args: ['--stdio'], env: { LOG: 'debug' } },
    linear: { url: 'https://mcp.linear.app', env_http_headers: { Authorization: 'MECH_X' } },
  })

  assert.match(block, /\[mcp_servers\.git\]/)
  assert.match(block, /command = "\/usr\/bin\/git-mcp"/)
  assert.match(block, /args = \["--stdio"\]/)
  assert.match(block, /env = \{ LOG = "debug" \}/)
  assert.match(block, /\[mcp_servers\.linear\]/)
  assert.match(block, /env_http_headers = \{ Authorization = "MECH_X" \}/)
})

test('credential variables are excluded from the agent shell environment', () => {
  const block = renderManagedCodexConfig({}, { exclusions: ['GITHUB_TOKEN', 'MECHANICIAN_MCP_AB'] })

  assert.match(block, /\[shell_environment_policy\]/)
  assert.match(block, /exclude = \["GITHUB_TOKEN", "MECHANICIAN_MCP_AB"\]/)
})

test('managed exclusions round-trip from the shared region', () => {
  const config = mergeManagedCodexConfig(CODEX_OWNED, renderManagedCodexConfig({}, {
    exclusions: ['MECHANICIAN_MCP_A', 'MECHANICIAN_MCP_B'],
  }))

  assert.deepEqual(managedCodexExclusions(config), [
    'MECHANICIAN_MCP_A', 'MECHANICIAN_MCP_B',
  ])
})

test('a name that is not a bare TOML key is quoted', () => {
  const block = renderManagedCodexConfig({ 'my server.v2': { command: 'x' } })
  assert.match(block, /\[mcp_servers\."my server\.v2"\]/)
})

test('TOML strings escape every ASCII control that may arrive from a registry', () => {
  const block = renderManagedCodexConfig({
    'name\r\t\0': { command: 'command\r\t\0', args: ['line\nnext'] },
  })

  assert.match(block, /\[mcp_servers\."name\\r\\t\\u0000"\]/)
  assert.match(block, /command = "command\\r\\t\\u0000"/)
  assert.match(block, /args = \["line\\nnext"\]/)
  assert.equal(/[\r\t\0]/.test(block), false, 'no raw control reaches config.toml')
})

test('merging into a file Codex owns leaves its own settings byte-identical', () => {
  const merged = mergeManagedCodexConfig(CODEX_OWNED, renderManagedCodexConfig({ a: { command: 'x' } }))

  assert.ok(merged.startsWith(CODEX_OWNED), 'Codex-authored content is untouched and stays first')
  assert.match(merged, /\[projects\."\/Users\/someone\/code"\]/)
  assert.match(merged, /trust_level = "trusted"/)
  assert.match(merged, /\[mcp_servers\.a\]/)
})

test('rewriting replaces the managed region instead of stacking copies', () => {
  const first = mergeManagedCodexConfig(CODEX_OWNED, renderManagedCodexConfig({ a: { command: 'x' } }))
  const second = mergeManagedCodexConfig(first, renderManagedCodexConfig({ b: { command: 'y' } }))

  assert.equal(second.split(BLOCK_BEGIN).length - 1, 1, 'exactly one managed region')
  assert.equal(second.split(BLOCK_END).length - 1, 1)
  assert.doesNotMatch(second, /\[mcp_servers\.a\]/, 'the removed server is gone')
  assert.match(second, /\[mcp_servers\.b\]/)
  assert.match(second, /trust_level = "trusted"/, 'and Codex keeps its own settings')
})

/// A no-op reload must not churn the file Codex is watching.
test('the same servers produce a byte-identical file', () => {
  const block = renderManagedCodexConfig({ a: { command: 'x' } })
  const once = mergeManagedCodexConfig(CODEX_OWNED, block)
  assert.equal(mergeManagedCodexConfig(once, block), once)
})

test('an interrupted half-written region is repaired, not nested', () => {
  const truncated = `${CODEX_OWNED}${BLOCK_BEGIN}\n[mcp_servers.hal`
  const merged = mergeManagedCodexConfig(truncated, renderManagedCodexConfig({ a: { command: 'x' } }))

  assert.equal(merged.split(BLOCK_BEGIN).length - 1, 1)
  assert.doesNotMatch(merged, /mcp_servers\.hal/)
  assert.match(merged, /trust_level = "trusted"/)
})

/// TOML rejects a duplicate table outright, which would make Codex refuse the WHOLE file — so a
/// name already declared outside our region has to be detected before we write it.
test('server names declared outside the managed region are reported', () => {
  const existing = [
    CODEX_OWNED,
    '[mcp_servers.openaiDeveloperDocs]',
    'url = "https://developers.openai.com/mcp"',
    '',
    '[mcp_servers."odd name"]',
    'command = "x"',
    '',
    renderManagedCodexConfig({ ours: { command: 'y' } }),
  ].join('\n')

  const foreign = foreignServerNames(existing)

  assert.ok(foreign.has('openaiDeveloperDocs'))
  assert.ok(foreign.has('odd name'))
  assert.equal(foreign.has('ours'), false, 'our own region must not count as foreign')
  assert.deepEqual([...configuredServerNames(existing)].sort(), [
    'odd name', 'openaiDeveloperDocs', 'ours',
  ])
})

test('foreign shell policy detection covers quoted, commented, and dotted TOML forms', () => {
  for (const config of [
    '[shell_environment_policy] # Codex comment\nexclude = []\n',
    '["shell_environment_policy"]\nexclude = []\n',
    "['shell_environment_policy']\nexclude = []\n",
    'shell_environment_policy.exclude = ["TOKEN"]\n',
    '"shell_environment_policy".exclude = ["TOKEN"]\n',
  ]) {
    assert.equal(hasForeignShellEnvironmentPolicy(config), true, config)
  }
  assert.equal(
    hasForeignShellEnvironmentPolicy('label = "[shell_environment_policy] # value"\n'),
    false,
  )
})

test('foreign MCP names cover quoted escapes, literal keys, and dotted assignments', () => {
  const configurations = [
    ['["mcp_servers"."quoted name"]\ncommand = "x"\n', 'quoted name'],
    ["[mcp_servers.'literal.name']\ncommand = 'x'\n", 'literal.name'],
    ['[mcp_servers."escaped\\\\name"]\ncommand = "x"\n', 'escaped\\name'],
    ['mcp_servers.dotted.command = "x"\n', 'dotted'],
    ['[mcp_servers]\nnested.command = "x"\n', 'nested'],
  ]
  for (const [config, expected] of configurations) {
    assert.deepEqual([...foreignServerNames(config)], [expected], config)
  }
})

test('an empty or absent file just gets the region', () => {
  const merged = mergeManagedCodexConfig('', renderManagedCodexConfig({ a: { command: 'x' } }))
  assert.ok(merged.startsWith(BLOCK_BEGIN))
  assert.equal(foreignServerNames(merged).size, 0)
})
