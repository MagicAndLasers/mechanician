import assert from 'node:assert/strict'
import { test } from 'node:test'

import {
  DEFAULT_CREDENTIAL_SERVICES,
  credentialServices,
  validatedCredentialService,
} from '../src/credential-services.mjs'

test('credential services retain the public names with no tenant environment', () => {
  assert.deepEqual(credentialServices({}), DEFAULT_CREDENTIAL_SERVICES)
})

test('credential services accept the bundle-derived Acme namespaces', () => {
  assert.deepEqual(credentialServices({
    MECHANICIAN_ANTHROPIC_API_KEY_SERVICE: 'ANTHROPIC_API_KEY.acme',
    MECHANICIAN_OPENAI_API_KEY_SERVICE: 'OPENAI_API_KEY.acme',
    MECHANICIAN_MCP_SECRET_SERVICE: 'ai.mechanician.mcp-secret.acme',
    MECHANICIAN_MCP_OAUTH_SERVICE: 'ai.mechanician.mcp-oauth.acme',
  }), {
    anthropicAPIKey: 'ANTHROPIC_API_KEY.acme',
    openAIAPIKey: 'OPENAI_API_KEY.acme',
    mcpSecret: 'ai.mechanician.mcp-secret.acme',
    mcpOAuth: 'ai.mechanician.mcp-oauth.acme',
  })
})

test('invalid service names fail closed to the named default', () => {
  assert.equal(validatedCredentialService('bad service', 'safe.default'), 'safe.default')
  assert.equal(validatedCredentialService('../other', 'safe.default'), 'safe.default')
  assert.equal(validatedCredentialService('safe.name-1', 'safe.default'), 'safe.name-1')
})
