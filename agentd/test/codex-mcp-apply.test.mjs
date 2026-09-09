import assert from 'node:assert/strict'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import test from 'node:test'
import { spawn } from 'node:child_process'

import {
  applyCodexMcpConfig,
  codexMcpConfigurationFingerprint,
  codexMcpEnvChanged,
} from '../src/codex-mcp-apply.mjs'
import { publishCodexMcpCredentialGeneration } from '../src/codex-mcp-generation.mjs'
import { MCP_SECRET_PREFIX } from '../src/mcp-secrets.mjs'

const secret = (account) => `${MCP_SECRET_PREFIX}${account}`

function workspace(servers, { existingConfig } = {}) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'codex-apply-'))
  const extensionsFile = path.join(root, 'extensions.json')
  const codexHome = path.join(root, 'codex')
  fs.writeFileSync(extensionsFile, JSON.stringify({ mcpServers: servers }))
  if (existingConfig !== undefined) {
    fs.mkdirSync(codexHome, { recursive: true })
    fs.writeFileSync(path.join(codexHome, 'config.toml'), existingConfig)
  }
  return { root, extensionsFile, codexHome }
}

function apply(ws, readSecret = () => 'resolved-secret', retainedExclusions = []) {
  return applyCodexMcpConfig({
    extensionsFile: ws.extensionsFile, codexHome: ws.codexHome, readSecret, retainedExclusions,
  })
}

test('servers are written to config.toml and credentials only to the environment', () => {
  const ws = workspace([
    { name: 'git', command: '/bin/echo', args: ['--stdio'] },
    { name: 'gh', command: '/bin/echo', env: { GITHUB_TOKEN: secret('acct-1') } },
  ])

  const result = apply(ws)
  const config = fs.readFileSync(result.configPath, 'utf8')

  assert.deepEqual(result.servers.sort(), ['gh', 'git'])
  assert.equal(result.env.GITHUB_TOKEN, 'resolved-secret')
  assert.match(config, /\[mcp_servers\.git\]/)
  assert.match(config, /env_vars = \["GITHUB_TOKEN"\]/)
  assert.equal(config.includes('resolved-secret'), false, 'the secret never reaches the file')
})

/// Codex inherits agentd's whole environment and runs shell commands for the model, so a variable
/// that carries a credential has to be excluded again or every command can read it.
test('credential variables are excluded from the agent shell environment', () => {
  const ws = workspace([{ name: 'gh', command: '/bin/echo', env: { GITHUB_TOKEN: secret('a') } }])

  const config = fs.readFileSync(apply(ws).configPath, 'utf8')

  assert.match(config, /\[shell_environment_policy\]/)
  assert.match(config, /exclude = \["GITHUB_TOKEN"\]/)
})

test('a cleared credential remains excluded while an old app-server process may retain it', () => {
  const ws = workspace([])

  const result = apply(ws, () => 'unused', ['MECHANICIAN_MCP_RETIRED'])
  const config = fs.readFileSync(result.configPath, 'utf8')

  assert.deepEqual(result.env, {})
  assert.deepEqual(result.exclusions, ['MECHANICIAN_MCP_RETIRED'])
  assert.match(config, /exclude = \["MECHANICIAN_MCP_RETIRED"\]/)
})

test('a sibling process cannot erase an exclusion written by another MCP generation', () => {
  const ws = workspace([])
  apply(ws, () => 'unused', ['MECHANICIAN_MCP_SIBLING'])

  const result = apply(ws)

  assert.deepEqual(result.exclusions, ['MECHANICIAN_MCP_SIBLING'])
  assert.match(
    fs.readFileSync(result.configPath, 'utf8'),
    /exclude = \["MECHANICIAN_MCP_SIBLING"\]/)
})

test('simultaneous process writers merge exclusions instead of losing one', async () => {
  const ws = workspace([])
  const modulePath = new URL('../src/codex-mcp-apply.mjs', import.meta.url).pathname
  const run = (name) => new Promise((resolve, reject) => {
    const script = [
      `import { applyCodexMcpConfig } from ${JSON.stringify(modulePath)}`,
      `applyCodexMcpConfig({extensionsFile:${JSON.stringify(ws.extensionsFile)},`,
      `codexHome:${JSON.stringify(ws.codexHome)},retainedExclusions:[${JSON.stringify(name)}]})`,
    ].join('\n')
    const child = spawn(process.execPath, ['--input-type=module', '--eval', script], {
      stdio: ['ignore', 'ignore', 'pipe'],
    })
    let error = ''
    child.stderr.on('data', (chunk) => { error += chunk })
    child.once('error', reject)
    child.once('exit', (code) => code === 0 ? resolve() : reject(new Error(error || `exit ${code}`)))
  })

  await Promise.all([
    run('MECHANICIAN_MCP_PROCESS_A'),
    run('MECHANICIAN_MCP_PROCESS_B'),
  ])

  const config = fs.readFileSync(path.join(ws.codexHome, 'config.toml'), 'utf8')
  assert.match(config, /MECHANICIAN_MCP_PROCESS_A/)
  assert.match(config, /MECHANICIAN_MCP_PROCESS_B/)
})

test('an App Server config mutation cannot be lost beneath an MCP rename', async () => {
  const ws = workspace([{ name: 'git', command: '/bin/echo' }])
  const initial = apply(ws)
  const ready = path.join(ws.root, 'mutation-lock-held')
  const lockModule = new URL('../src/codex-mcp-config-lock.mjs', import.meta.url).pathname
  const script = [
    `import fs from 'node:fs'`,
    `import { withCodexMcpConfigLock } from ${JSON.stringify(lockModule)}`,
    `await withCodexMcpConfigLock(${JSON.stringify(ws.codexHome)},async()=>{`,
    ` fs.writeFileSync(${JSON.stringify(ready)},'ready')`,
    ` await new Promise(resolve=>setTimeout(resolve,80))`,
    ` fs.appendFileSync(${JSON.stringify(initial.configPath)},`,
    `   '\\n[marketplaces.fixture]\\nsource = "owner/repository"\\n')`,
    `})`,
  ].join('\n')
  const child = spawn(process.execPath, ['--input-type=module', '--eval', script], {
    stdio: ['ignore', 'ignore', 'pipe'],
  })
  let childError = ''
  child.stderr.on('data', (chunk) => { childError += chunk })
  const childExit = new Promise((resolve, reject) => {
    child.once('error', reject)
    child.once('exit', (code) => code === 0
      ? resolve() : reject(new Error(childError || `child exited ${code}`)))
  })
  for (let count = 0; count < 200 && !fs.existsSync(ready); count += 1) {
    await new Promise((resolve) => setTimeout(resolve, 5))
  }
  assert.equal(fs.existsSync(ready), true)

  // This blocks on the other process's FD lock, then re-reads the App Server-authored bytes before
  // publishing the managed region. Without shared serialization the final rename loses the table.
  apply(ws)
  await childExit

  assert.match(fs.readFileSync(initial.configPath, 'utf8'), /\[marketplaces\.fixture\]/)
})

test('the file Codex owns survives a rewrite', () => {
  const existing = '[projects."/tmp/x"]\ntrust_level = "trusted"\n'
  const ws = workspace([{ name: 'git', command: '/bin/echo' }], { existingConfig: existing })

  const config = fs.readFileSync(apply(ws).configPath, 'utf8')

  assert.match(config, /trust_level = "trusted"/)
  assert.match(config, /\[mcp_servers\.git\]/)
})

test('a foreign shell environment policy fails safely instead of duplicating its TOML table', () => {
  const existing = '[shell_environment_policy]\ninherit = "core"\n'
  const ws = workspace([
    { name: 'secret', command: '/bin/echo', env: { TOKEN: secret('account') } },
  ], { existingConfig: existing })

  assert.throws(() => apply(ws), /shell_environment_policy outside Mechanician/)
  assert.equal(fs.readFileSync(path.join(ws.codexHome, 'config.toml'), 'utf8'), existing)
})

test('a malformed managed exclusion policy fails closed', () => {
  const malformed = [
    '# >>> mechanician managed MCP servers — do not edit >>>',
    '[shell_environment_policy]',
    'exclude = not-an-array',
    '# <<< mechanician managed MCP servers <<<',
  ].join('\n')
  const ws = workspace([], { existingConfig: malformed })

  assert.throws(() => apply(ws), /managed Codex shell exclusion policy is malformed/)
  assert.equal(fs.readFileSync(path.join(ws.codexHome, 'config.toml'), 'utf8'), malformed)
})

/// A duplicate table makes Codex reject the ENTIRE config, so one clashing name must not cost the
/// user every other server plus their own settings.
test('a name already configured outside Mechanician is skipped, not duplicated', () => {
  const existing = '[mcp_servers.git]\ncommand = "theirs"\n'
  const ws = workspace([{ name: 'git', command: '/bin/echo' }], { existingConfig: existing })

  const result = apply(ws)

  assert.deepEqual(result.servers, [])
  assert.equal(result.unsupported.length, 1)
  assert.match(result.unsupported[0].reason, /already configured in Codex/)
})

/// Mounting it anyway would fail at connect time with a message naming our internal variable, which
/// explains nothing to the user.
test('a server whose Keychain secret cannot be read is dropped with a reason', () => {
  const ws = workspace([
    { name: 'ok', command: '/bin/echo' },
    { name: 'broken', command: '/bin/echo', env: { TOKEN: secret('missing') } },
  ])

  const result = apply(ws, () => { throw new Error('keychain item not found') })

  assert.deepEqual(result.servers, ['ok'])
  assert.equal(Object.keys(result.env).length, 0, 'no half-resolved variable is exported')
  assert.match(result.unsupported.find((u) => u.name === 'broken').reason, /Keychain/)
})

test('a missing extensions file clears the managed region rather than leaving it stale', () => {
  const ws = workspace([{ name: 'git', command: '/bin/echo' }])
  apply(ws)
  fs.rmSync(ws.extensionsFile)

  const result = apply(ws)

  assert.deepEqual(result.servers, [])
  assert.doesNotMatch(fs.readFileSync(result.configPath, 'utf8'), /\[mcp_servers\./)
})

test('the config file is written 0600', () => {
  const ws = workspace([{ name: 'git', command: '/bin/echo' }])

  const mode = fs.statSync(apply(ws).configPath).mode & 0o777

  assert.equal(mode, 0o600)
})

test('an identical apply preserves the config inode and modification time', () => {
  const ws = workspace([{ name: 'git', command: '/bin/echo' }])
  const first = apply(ws)
  const before = fs.statSync(first.configPath, { bigint: true })

  const second = apply(ws)
  const after = fs.statSync(second.configPath, { bigint: true })

  assert.equal(second.configPath, first.configPath)
  assert.equal(after.ino, before.ino)
  assert.equal(after.mtimeNs, before.mtimeNs)
})

/// Definitions reload from the file; credentials cannot, because the process environment is fixed
/// at spawn. Knowing the difference is what lets a reload be honest about what it applied.
test('an environment change is detected so a reload can say it needs a restart', () => {
  assert.equal(codexMcpEnvChanged({}, {}), false)
  assert.equal(codexMcpEnvChanged({ A: '1' }, { A: '1' }), false)
  assert.equal(codexMcpEnvChanged({ A: '1' }, { A: '2' }), true, 'rotated secret')
  assert.equal(codexMcpEnvChanged({ A: '1' }, {}), true, 'server removed')
  assert.equal(codexMcpEnvChanged({}, { A: '1' }), true, 'server added')
})

test('the cross-window generation fingerprint changes for config or credential rotation', () => {
  const ws = workspace([{
    name: 'git', command: '/bin/echo', env: { TOKEN: secret('fingerprint') },
  }])
  let credential = 'one'
  apply(ws, () => credential)
  const baseline = codexMcpConfigurationFingerprint({
    extensionsFile: ws.extensionsFile,
    codexHome: ws.codexHome,
    readSecret: () => credential,
  })

  assert.equal(
    codexMcpConfigurationFingerprint({
      extensionsFile: ws.extensionsFile,
      codexHome: ws.codexHome,
      readSecret: () => credential,
    }),
    baseline,
    'an unchanged credential source is the same generation')
  credential = 'rotated'
  assert.notEqual(
    codexMcpConfigurationFingerprint({
      extensionsFile: ws.extensionsFile,
      codexHome: ws.codexHome,
      readSecret: () => credential,
    }),
    baseline)

  fs.writeFileSync(ws.extensionsFile, JSON.stringify({
    mcpServers: [{ name: 'other', command: '/bin/echo' }],
  }))
  assert.notEqual(
    codexMcpConfigurationFingerprint({
      extensionsFile: ws.extensionsFile,
      codexHome: ws.codexHome,
      readSecret: () => credential,
    }),
    baseline)
})

test('Codex-owned OAuth advances the cross-window fingerprint without config or env changes', () => {
  const ws = workspace([{ name: 'remote', transport: 'http', url: 'https://mcp.test' }])
  apply(ws)
  const baseline = codexMcpConfigurationFingerprint({
    extensionsFile: ws.extensionsFile,
    codexHome: ws.codexHome,
  })

  publishCodexMcpCredentialGeneration(ws.codexHome, 'oauth-generation-2')

  assert.notEqual(codexMcpConfigurationFingerprint({
    extensionsFile: ws.extensionsFile,
    codexHome: ws.codexHome,
  }), baseline)
  assert.equal(
    JSON.parse(fs.readFileSync(
      path.join(ws.codexHome, '.mechanician-mcp-credentials.generation'), 'utf8')).revision,
    'oauth-generation-2',
  )
})

test('cross-window convergence ignores non-provider extension ledger rewrites', () => {
  const ws = workspace([{ name: 'remote', transport: 'http', url: 'https://mcp.test' }])
  const initial = JSON.parse(fs.readFileSync(ws.extensionsFile, 'utf8'))
  initial.providerConfigurationRevision = 'revision-a'
  initial.pendingMCPReadiness = { byAccess: { codex_subscription: ['pending'] } }
  fs.writeFileSync(ws.extensionsFile, JSON.stringify(initial))
  const baseline = codexMcpConfigurationFingerprint({
    extensionsFile: ws.extensionsFile, codexHome: ws.codexHome,
  })

  fs.writeFileSync(ws.extensionsFile, JSON.stringify({
    registrySources: [{ name: 'unrelated' }],
    pendingMCPReadiness: { byAccess: {} },
    mcpServers: initial.mcpServers,
    providerConfigurationRevision: 'revision-a',
  }, null, 2))

  assert.equal(codexMcpConfigurationFingerprint({
    extensionsFile: ws.extensionsFile, codexHome: ws.codexHome,
  }), baseline)
})
