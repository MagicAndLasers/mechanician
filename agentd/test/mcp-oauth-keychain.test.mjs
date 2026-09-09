import assert from 'node:assert/strict'
import { test } from 'node:test'

import {
  createMcpOAuthKeychain,
  mcpOAuthBinding,
} from '../src/mcp-oauth-keychain.mjs'

const server = {
  id: '7F661A72-4885-42AD-BCE1-242B6741D88A',
  name: 'Confluence', transport: 'http', url: 'https://confluence.mcp.example.com/mcp',
}

function memoryKeychainHelper() {
  const items = new Map()
  const calls = []
  return {
    calls,
    run(operation, service, account, input) {
      calls.push({ operation, service, account, input })
      const key = `${service}\0${account}`
      if (operation === 'read') {
        return items.has(key) ? { status: 0, stdout: items.get(key) } : { status: 44, stdout: '' }
      }
      if (operation === 'write') {
        items.set(key, input)
        return { status: 0, stdout: '' }
      }
      if (operation === 'delete') {
        if (!items.has(key)) return { status: 44, stdout: '' }
        items.delete(key); return { status: 0, stdout: '' }
      }
      return { status: 1, stdout: '' }
    },
  }
}

test('OAuth records round-trip through Keychain without placing a secret in argv', () => {
  const helper = memoryKeychainHelper()
  const keychain = createMcpOAuthKeychain({ service: 'test.mcp-oauth', runHelper: helper.run })
  const binding = mcpOAuthBinding(server, 'anthropic:vertex:route-v1:abc')
  keychain.write(binding, { tokens: { access_token: 'secret-access-token', token_type: 'Bearer' } })
  assert.equal(keychain.read(binding).tokens.access_token, 'secret-access-token')
  const write = helper.calls.find((call) => call.operation === 'write')
  assert.ok(write)
  assert.doesNotMatch([write.operation, write.service, write.account].join(' '), /secret-access-token/)
  assert.match(write.input, /secret-access-token/)
})

test('records are inert after an endpoint or provider-route change', () => {
  const helper = memoryKeychainHelper()
  const keychain = createMcpOAuthKeychain({ service: 'test.mcp-oauth', runHelper: helper.run })
  const original = mcpOAuthBinding(server, 'anthropic:vertex:route-v1:abc')
  keychain.write(original, { tokens: { access_token: 'secret', token_type: 'Bearer' } })
  assert.equal(keychain.read(mcpOAuthBinding(
    { ...server, url: 'https://other.mcp.example.com/mcp' },
    'anthropic:vertex:route-v1:abc',
  )), null)
  assert.equal(keychain.read(mcpOAuthBinding(server, 'anthropic:subscription')), null)
})

test('Clear Auth is idempotent and removes only the exact route/server item', () => {
  const helper = memoryKeychainHelper()
  const keychain = createMcpOAuthKeychain({ service: 'test.mcp-oauth', runHelper: helper.run })
  const vertex = mcpOAuthBinding(server, 'anthropic:vertex:route-v1:abc')
  const subscription = mcpOAuthBinding(server, 'anthropic:subscription')
  keychain.write(vertex, { tokens: { access_token: 'vertex', token_type: 'Bearer' } })
  keychain.write(subscription, { tokens: { access_token: 'subscription', token_type: 'Bearer' } })
  keychain.remove(vertex)
  keychain.remove(vertex)
  assert.equal(keychain.read(vertex), null)
  assert.equal(keychain.read(subscription).tokens.access_token, 'subscription')
})

test('OAuth rejects insecure non-loopback endpoints and unstable identities', () => {
  assert.throws(() => mcpOAuthBinding({ ...server, url: 'http://example.com/mcp' }, 'route'), /HTTPS/)
  assert.throws(() => mcpOAuthBinding({ ...server, id: '' }, 'route'), /stable server identifier/)
  assert.doesNotThrow(() => mcpOAuthBinding({ ...server, url: 'http://127.0.0.1:4321/mcp' }, 'route'))
})
