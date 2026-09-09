import assert from 'node:assert/strict'
import { randomUUID } from 'node:crypto'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { test } from 'node:test'

import {
  MCP_SECRET_PREFIX,
  accountFromMCPSecretReference,
  expectedMCPSecretAccountPrefix,
  loadUserExtensionsFile,
  resolveMCPSecretMap,
} from '../src/mcp-secrets.mjs'

const nonce = '2b4794c9-4bb5-4fd0-924a-c871ca93c24e'

function reference(server, kind, key) {
  const account = expectedMCPSecretAccountPrefix(server, kind, key) + nonce
  return MCP_SECRET_PREFIX + Buffer.from(account, 'utf8').toString('base64url')
}

test('MCP Keychain references resolve without exposing a credential in JSON', () => {
  const server = {
    id: '7F661A72-4885-42AD-BCE1-242B6741D88A', name: 'local', transport: 'stdio',
    command: '/usr/bin/env', args: ['node'], env: {},
  }
  const value = reference(server, 'env', 'API_TOKEN')
  const account = accountFromMCPSecretReference(value)
  const resolved = resolveMCPSecretMap(
    { API_TOKEN: value }, server, 'env', (requested) => {
      assert.equal(requested, account)
      return 'super-secret'
    },
  )
  assert.deepEqual(resolved, { API_TOKEN: 'super-secret' })
  assert.doesNotMatch(value, /super-secret/)
})

test('a reference is bound to the MCP executable endpoint and field', () => {
  const server = {
    id: '7F661A72-4885-42AD-BCE1-242B6741D88A', name: 'local', transport: 'stdio',
    command: '/trusted/server', args: ['serve'], env: {},
  }
  const value = reference(server, 'env', 'API_TOKEN')
  assert.throws(
    () => resolveMCPSecretMap(
      { API_TOKEN: value }, { ...server, command: '/malicious/server' }, 'env', () => 'secret'),
    /reference is invalid/,
  )
  assert.throws(
    () => resolveMCPSecretMap({ OTHER_TOKEN: value }, server, 'env', () => 'secret'),
    /reference is invalid/,
  )
})

test('extension loading fails closed only for the server with a missing credential', (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'mechanician-mcp-secrets-'))
  t.after(() => fs.rmSync(root, { recursive: true, force: true }))
  const file = path.join(root, 'extensions.json')
  const local = {
    id: '7F661A72-4885-42AD-BCE1-242B6741D88A', name: 'local', transport: 'stdio',
    command: '/trusted/server', args: [], env: {}, enabled: true,
  }
  const remote = {
    id: '3755E05D-0EF2-44C0-8BB5-48DBBDE12C8D', name: 'remote', transport: 'http',
    url: 'https://example.com/mcp', headers: {}, enabled: true,
  }
  local.env.API_TOKEN = reference(local, 'env', 'API_TOKEN')
  remote.headers.Authorization = reference(remote, 'header', 'Authorization')
  fs.writeFileSync(file, JSON.stringify({ mcpServers: [local, remote], plugins: [] }))

  const loaded = loadUserExtensionsFile(file, {
    readSecret(account) {
      if (account.includes(local.id.toLowerCase())) throw new Error('missing')
      return 'Bearer remote-secret'
    },
  })

  assert.equal(loaded.servers.local, undefined)
  assert.deepEqual(loaded.servers.remote.headers, { Authorization: 'Bearer remote-secret' })
  assert.equal(loaded.servers.remote.alwaysLoad, undefined,
    'external MCP tools stay deferred so slow servers do not block every first response')
  assert.deepEqual(loaded.networkScopes, { remote: 'public' })
  assert.deepEqual(loaded.serverIds, { remote: remote.id })
  assert.deepEqual(loaded.oauthBindings, {
    remote: {
      id: remote.id, name: remote.name, transport: remote.transport, url: remote.url,
    },
  })
  assert.deepEqual(loaded.errors, [{
    name: 'local', message: 'MCP credentials could not be loaded securely.',
  }])
})

test('extension loading retains only the recognized VPN network scope as inert metadata', (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'mechanician-mcp-scope-'))
  t.after(() => fs.rmSync(root, { recursive: true, force: true }))
  const file = path.join(root, 'extensions.json')
  fs.writeFileSync(file, JSON.stringify({
    mcpServers: [
      { name: 'internal', transport: 'http', url: 'https://internal.example/mcp',
        networkScope: 'vpnOnly', enabled: true },
      { name: 'forged', transport: 'http', url: 'https://example.com/mcp',
        networkScope: 'arbitrary', enabled: true },
    ],
    plugins: [],
  }))

  const loaded = loadUserExtensionsFile(file)
  assert.deepEqual(loaded.networkScopes, { internal: 'vpnOnly', forged: 'public' })
  assert.equal(loaded.servers.internal.networkScope, undefined,
    'network metadata must not leak into the SDK MCP config')
  assert.equal(loaded.servers.internal.alwaysLoad, undefined)
  assert.equal(loaded.servers.forged.alwaysLoad, undefined)
})

test('legacy plaintext remains readable until the Swift store migrates it', () => {
  const server = { id: randomUUID(), transport: 'http', url: 'https://example.com' }
  assert.deepEqual(
    resolveMCPSecretMap({ Authorization: 'Bearer legacy' }, server, 'header'),
    { Authorization: 'Bearer legacy' },
  )
})
