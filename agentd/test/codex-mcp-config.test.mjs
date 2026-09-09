import assert from 'node:assert/strict'
import test from 'node:test'

import {
  codexSecretExclusions,
  mcpSecretEnvVarName,
  translateMcpServersForCodex,
} from '../src/codex-mcp-config.mjs'
import { MCP_SECRET_PREFIX } from '../src/mcp-secrets.mjs'

const secret = (account) => `${MCP_SECRET_PREFIX}${account}`

test('stdio servers translate to command/args and literal env', () => {
  const { servers, unsupported } = translateMcpServersForCodex([
    { name: 'git', command: '/usr/bin/git-mcp', args: ['--stdio'], env: { LOG: 'debug' } },
  ])

  assert.deepEqual(servers.git, {
    command: '/usr/bin/git-mcp',
    args: ['--stdio'],
    env: { LOG: 'debug' },
  })
  assert.deepEqual(unsupported, [])
})

test('a Keychain-backed stdio value never reaches the config, only its variable name', () => {
  const { servers, secretEnv } = translateMcpServersForCodex([
    { name: 'gh', command: 'gh-mcp', env: { GITHUB_TOKEN: secret('acct-1'), LOG: 'info' } },
  ])

  // Codex forwards env_vars BY NAME, so the server still sees GITHUB_TOKEN.
  assert.deepEqual(servers.gh.env_vars, ['GITHUB_TOKEN'])
  assert.deepEqual(servers.gh.env, { LOG: 'info' }, 'literals stay, the secret does not')
  assert.equal(JSON.stringify(servers).includes('acct-1'), false, 'no reference in the config')
  assert.deepEqual(secretEnv, [{
    variable: 'GITHUB_TOKEN',
    reference: secret('acct-1'),
    server: 'gh',
    kind: 'env',
    key: 'GITHUB_TOKEN',
  }])
})

test('remote headers indirect through a generated variable, never a literal token', () => {
  const { servers, secretEnv } = translateMcpServersForCodex([
    {
      name: 'linear',
      transport: 'http',
      url: 'https://mcp.linear.app/sse',
      headers: { Authorization: secret('acct-2'), 'X-Client': 'mechanician' },
    },
  ])

  const variable = mcpSecretEnvVarName('linear', 'header', 'Authorization')
  assert.deepEqual(servers.linear.env_http_headers, { Authorization: variable })
  assert.deepEqual(servers.linear.http_headers, { 'X-Client': 'mechanician' })
  assert.equal(servers.linear.bearer_token, undefined, 'Codex hard-rejects a literal bearer_token')
  assert.equal(secretEnv[0].variable, variable)
  assert.match(variable, /^MECHANICIAN_MCP_[0-9A-F]{16}$/)
})

test('generated variable names are stable and distinct per server and header', () => {
  assert.equal(
    mcpSecretEnvVarName('a', 'header', 'Authorization'),
    mcpSecretEnvVarName('a', 'header', 'Authorization'))
  assert.notEqual(
    mcpSecretEnvVarName('a', 'header', 'Authorization'),
    mcpSecretEnvVarName('b', 'header', 'Authorization'))
})

/// stdio forwarding is by name and cannot rename, so this case is genuinely unrepresentable —
/// handing the second server the first one's credential would be the alternative.
test('two stdio servers wanting one variable for different secrets is reported, not guessed', () => {
  const { servers, unsupported } = translateMcpServersForCodex([
    { name: 'first', command: 'a', env: { API_KEY: secret('acct-1') } },
    { name: 'second', command: 'b', env: { API_KEY: secret('acct-2') } },
  ])

  assert.ok(servers.first)
  assert.equal(servers.second, undefined)
  assert.equal(unsupported.length, 1)
  assert.match(unsupported[0].reason, /already used by “first”/)
})

test('the same secret under one variable is not a collision', () => {
  const { servers, unsupported } = translateMcpServersForCodex([
    { name: 'first', command: 'a', env: { API_KEY: secret('shared') } },
    { name: 'second', command: 'b', env: { API_KEY: secret('shared') } },
  ])

  assert.ok(servers.first && servers.second)
  assert.deepEqual(unsupported, [])
})

test('SSE is reported as unsupported rather than silently dropped', () => {
  const { servers, unsupported } = translateMcpServersForCodex([
    { name: 'legacy', transport: 'sse', url: 'https://example.test/sse' },
  ])

  assert.deepEqual(servers, {})
  assert.equal(unsupported.length, 1)
  assert.match(unsupported[0].reason, /SSE is not supported/)
})

test('disabled and incomplete servers are skipped without noise', () => {
  const { servers, unsupported } = translateMcpServersForCodex([
    { name: 'off', command: 'x', enabled: false },
    { name: 'nocommand' },
    { name: 'nourl', transport: 'http' },
    null,
  ])

  assert.deepEqual(servers, {})
  assert.deepEqual(unsupported, [])
})

test('every credential variable is excluded from the agent shell environment', () => {
  const { secretEnv } = translateMcpServersForCodex([
    { name: 'gh', command: 'a', env: { GITHUB_TOKEN: secret('acct-1') } },
    { name: 'linear', transport: 'http', url: 'https://x.test', headers: { Authorization: secret('acct-2') } },
  ])

  const excluded = codexSecretExclusions(secretEnv)
  assert.equal(excluded.length, 2)
  assert.ok(excluded.includes('GITHUB_TOKEN'))
  assert.ok(excluded.includes(mcpSecretEnvVarName('linear', 'header', 'Authorization')))
})
