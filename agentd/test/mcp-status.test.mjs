import assert from 'node:assert/strict'
import { test } from 'node:test'

import { configuredMcpStatusPayload } from '../src/mcp-status.mjs'

test('configured status reports Keychain authorization without opening a provider query', () => {
  const payload = configuredMcpStatusPayload({
    servers: {
      VICE: { type: 'http', url: 'https://vice.example/mcp' },
      Confluence: { type: 'http', url: 'https://confluence.example/mcp' },
    },
    authorizationStates: {
      VICE: 'authenticated',
      Confluence: 'needs-auth',
    },
    networkScopes: { VICE: 'vpnOnly', Confluence: 'vpnOnly' },
  })
  assert.deepEqual(payload.map(({ name, status, tools, foreign }) =>
    ({ name, status, tools, foreign })), [
    { name: 'Confluence', status: 'needs-auth', tools: null, foreign: false },
    { name: 'VICE', status: 'authenticated', tools: null, foreign: false },
  ])
})

test('configured status surfaces secure credential loading failures', () => {
  const payload = configuredMcpStatusPayload({
    servers: {},
    errors: [{ name: 'VICE', message: 'MCP credentials could not be loaded securely.' }],
  })
  assert.equal(payload[0].status, 'failed')
  assert.match(payload[0].error, /securely/)
})

test('configured status does not claim unverified local servers have mounted tools', () => {
  const payload = configuredMcpStatusPayload({
    servers: { local: { type: 'stdio', command: '/bin/true' } },
  })
  assert.equal(payload[0].status, 'configured')
  assert.equal(payload[0].tools, null)
})
