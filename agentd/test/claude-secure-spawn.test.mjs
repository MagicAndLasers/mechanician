import assert from 'node:assert/strict'
import fs from 'node:fs'
import { once } from 'node:events'
import os from 'node:os'
import path from 'node:path'
import { test } from 'node:test'
import { fileURLToPath } from 'node:url'
import {
  classifyClaudeSubscriptionAuthStatus,
  claudeOAuthAccessTokenFromCredential,
  claudeCredentialFromEnvironment,
  directClaudeEnvironment,
  isClaudeSubscriptionAuthStatus,
  secureClaudeCodeSpawn,
  withoutClaudeSecrets,
} from '../src/claude-secure-spawn.mjs'

async function collect(stream) {
  let output = ''
  stream.setEncoding('utf8')
  for await (const chunk of stream) output += chunk
  return output
}

const here = path.dirname(fileURLToPath(import.meta.url))

for (const example of [
  {
    name: 'Anthropic API key',
    credential: { kind: 'apiKey', value: 'sk-ant-test-secret' },
    descriptorName: 'CLAUDE_CODE_API_KEY_FILE_DESCRIPTOR',
  },
  {
    name: 'Claude OAuth token',
    credential: { kind: 'oauth', value: 'oauth-test-secret' },
    descriptorName: 'CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR',
  },
]) {
  test(`${example.name} reaches Claude through a one-shot descriptor`, async () => {
    const spawnClaude = secureClaudeCodeSpawn(example.credential)
    const childProgram = `
      const fs = require('node:fs');
      const { spawnSync } = require('node:child_process');
      const fd = Number(process.env[${JSON.stringify(example.descriptorName)}]);
      const secret = fs.readFileSync(fd, 'utf8');
      const grandchild = spawnSync(process.execPath, ['-e',
        'const fs=require("node:fs"); let readable=true; try { fs.readFileSync(3) } catch { readable=false }; process.stdout.write(JSON.stringify({ api:process.env.ANTHROPIC_API_KEY, oauth:process.env.CLAUDE_CODE_OAUTH_TOKEN, openai:process.env.OPENAI_API_KEY, readable }))'
      ], { encoding: 'utf8' });
      process.stdout.write(JSON.stringify({
        secret,
        api: process.env.ANTHROPIC_API_KEY,
        bearer: process.env.ANTHROPIC_AUTH_TOKEN,
        oauth: process.env.CLAUDE_CODE_OAUTH_TOKEN,
        openai: process.env.OPENAI_API_KEY,
        descriptor: process.env[${JSON.stringify(example.descriptorName)}],
        grandchild: JSON.parse(grandchild.stdout),
      }));
    `
    const child = spawnClaude({
      command: process.execPath,
      args: ['-e', childProgram],
      env: {
        ...process.env,
        ANTHROPIC_API_KEY: 'must-not-leak',
        ANTHROPIC_AUTH_TOKEN: 'must-not-leak',
        CLAUDE_CODE_OAUTH_TOKEN: 'must-not-leak',
        OPENAI_API_KEY: 'must-not-leak',
      },
      signal: new AbortController().signal,
    })
    const output = collect(child.stdout)
    await once(child, 'exit')
    const observed = JSON.parse(await output)

    assert.equal(observed.secret, example.credential.value)
    assert.equal(observed.api, undefined)
    assert.equal(observed.bearer, undefined)
    assert.equal(observed.oauth, undefined)
    assert.equal(observed.openai, undefined)
    assert.equal(observed.descriptor, '3')
    assert.deepEqual(observed.grandchild, { readable: false })
  })
}

test('credential selection is lane-specific when both values exist', () => {
  const environment = {
    ANTHROPIC_API_KEY: 'api',
    CLAUDE_CODE_OAUTH_TOKEN: 'oauth',
  }
  assert.deepEqual(claudeCredentialFromEnvironment({
    ...environment,
  }, 'oauth'), { kind: 'oauth', value: 'oauth' })
  assert.deepEqual(claudeCredentialFromEnvironment(environment, 'apiKey'), {
    kind: 'apiKey', value: 'api',
  })
  assert.equal(claudeCredentialFromEnvironment({}, 'apiKey'), null)
  assert.equal(claudeCredentialFromEnvironment(environment, undefined), null)
  assert.equal(claudeCredentialFromEnvironment({ ANTHROPIC_API_KEY: ' \t\n ' }, 'apiKey'), null)
})

test('secret scrubbing removes credentials and stale descriptor variables', () => {
  const scrubbed = withoutClaudeSecrets({
    SAFE: 'yes',
    ANTHROPIC_API_KEY: 'secret',
    ANTHROPIC_AUTH_TOKEN: 'secret',
    CLAUDE_CODE_OAUTH_TOKEN: 'secret',
    OPENAI_API_KEY: 'secret',
    CLAUDE_CODE_API_KEY_FILE_DESCRIPTOR: '8',
    CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR: '9',
  })
  assert.deepEqual(scrubbed, { SAFE: 'yes' })
})

test('direct Anthropic routes discard unsupported backend and endpoint overrides', () => {
  const routeKeys = [
    'CLAUDE_CODE_USE_VERTEX', 'CLAUDE_CODE_USE_BEDROCK', 'CLAUDE_CODE_USE_FOUNDRY',
    'CLAUDE_CODE_USE_GATEWAY', 'CLAUDE_CODE_USE_MANTLE', 'CLAUDE_CODE_USE_ANTHROPIC_AWS',
    'ANTHROPIC_BASE_URL', 'ANTHROPIC_BEDROCK_BASE_URL',
    'ANTHROPIC_BEDROCK_MANTLE_BASE_URL', 'ANTHROPIC_VERTEX_BASE_URL',
    'ANTHROPIC_FOUNDRY_BASE_URL', 'ANTHROPIC_AWS_BASE_URL', 'CLAUDE_CODE_API_BASE_URL',
  ]
  const scrubbed = directClaudeEnvironment(Object.fromEntries([
    ['SAFE', 'yes'],
    ...routeKeys.map((name) => [name, 'must-not-route']),
  ]))
  assert.deepEqual(scrubbed, { SAFE: 'yes' })
})

test('direct Claude children leave prompt-suggestion policy to each query', () => {
  for (const inheritedPolicy of ['false', 'true']) {
    const environment = {
      SAFE: 'yes',
      CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION: inheritedPolicy,
    }
    assert.deepEqual(directClaudeEnvironment(environment), { SAFE: 'yes' })
    assert.equal(environment.CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION, inheritedPolicy)
  }
})

test('official Claude OAuth credentials expire and API-key status cannot satisfy subscription', () => {
  const now = 1_000_000
  assert.equal(claudeOAuthAccessTokenFromCredential({
    claudeAiOauth: { accessToken: 'live', expiresAt: now + 1 },
  }, now), 'live')
  assert.equal(claudeOAuthAccessTokenFromCredential({
    claudeAiOauth: { accessToken: 'expired', expiresAt: now },
  }, now), null)
  assert.equal(claudeOAuthAccessTokenFromCredential('{not json', now), null)
  assert.equal(isClaudeSubscriptionAuthStatus({ loggedIn: true, authMethod: 'oauth_token' }), true)
  assert.equal(isClaudeSubscriptionAuthStatus({
    loggedIn: true, authMethod: 'claude.ai', apiProvider: 'firstParty',
  }), true)
  assert.deepEqual(classifyClaudeSubscriptionAuthStatus({
    loggedIn: true, authMethod: 'third_party', apiProvider: 'vertex',
  }), {
    authenticated: false, reason: 'provider_conflict', method: 'third_party', provider: 'vertex',
  })
  assert.equal(isClaudeSubscriptionAuthStatus({
    loggedIn: true, authMethod: 'third_party', apiProvider: 'vertex',
  }), false)
  assert.equal(isClaudeSubscriptionAuthStatus({
    loggedIn: true, authMethod: 'claude.ai', apiProvider: 'vertex',
  }), false)
  assert.equal(isClaudeSubscriptionAuthStatus({ loggedIn: true, authMethod: 'api_key' }), false)
  assert.equal(isClaudeSubscriptionAuthStatus({ loggedIn: true, authMethod: 'apiKeyHelper' }), false)
  assert.equal(isClaudeSubscriptionAuthStatus({ loggedIn: false, authMethod: 'oauth_token' }), false)
})

test('the bundled Claude CLI recognizes both credential descriptor contracts', {
  skip: process.platform !== 'darwin' || process.arch !== 'arm64',
}, async () => {
  const cli = path.resolve(
    here, '../node_modules/@anthropic-ai/claude-agent-sdk-darwin-arm64/claude')
  assert.equal(fs.existsSync(cli), true, 'bundled Claude CLI is missing')
  const isolatedHome = fs.mkdtempSync(path.join(os.tmpdir(), 'mechanician-claude-auth-'))
  try {
    for (const example of [
      { credential: { kind: 'apiKey', value: 'sk-ant-descriptor-smoke' }, method: 'api_key' },
      { credential: { kind: 'oauth', value: 'oauth-descriptor-smoke' }, method: 'oauth_token' },
    ]) {
      const child = secureClaudeCodeSpawn(example.credential)({
        command: cli,
        args: ['auth', 'status', '--json'],
        cwd: here,
        env: {
          ...withoutClaudeSecrets(process.env),
          HOME: isolatedHome,
          XDG_CONFIG_HOME: path.join(isolatedHome, '.config'),
        },
        signal: new AbortController().signal,
      })
      const output = collect(child.stdout)
      await once(child, 'exit')
      assert.equal(child.exitCode, 0)
      const status = JSON.parse(await output)
      assert.equal(status.loggedIn, true)
      assert.equal(status.authMethod, example.method)
    }
  } finally {
    fs.rmSync(isolatedHome, { recursive: true, force: true })
  }
})
