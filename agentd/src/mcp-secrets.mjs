import fs from 'node:fs'
import { createHash } from 'node:crypto'
import { spawnSync } from 'node:child_process'
import { credentialServices } from './credential-services.mjs'

export const MCP_SECRET_SERVICE = credentialServices().mcpSecret
export const MCP_SECRET_PREFIX = `keychain://${MCP_SECRET_SERVICE}/v1/`

function encodeField(value) {
  return `${Buffer.byteLength(value, 'utf8')}:${value}`
}

export function mcpServerBindingDigest(server) {
  const transport = server.transport || 'stdio'
  const fields = transport === 'stdio'
    ? [transport, server.command || '', ...(server.args || []).map(String)]
    : [transport, server.url || '']
  return createHash('sha256').update(fields.map(encodeField).join('')).digest('hex')
}

export function expectedMCPSecretAccountPrefix(server, kind, key) {
  const id = typeof server.id === 'string' ? server.id.toLowerCase() : ''
  const keyToken = Buffer.from(key, 'utf8').toString('base64url')
  return `mcp-secret-v1|${id}|${mcpServerBindingDigest(server)}|${kind}|${keyToken}|`
}

export function accountFromMCPSecretReference(reference) {
  if (typeof reference !== 'string' || !reference.startsWith(MCP_SECRET_PREFIX)) return null
  const encoded = reference.slice(MCP_SECRET_PREFIX.length)
  if (!encoded || !/^[A-Za-z0-9_-]+$/.test(encoded)) return null
  try {
    const account = Buffer.from(encoded, 'base64url').toString('utf8')
    // Reject non-canonical encodings and invalid UTF-8 replacement characters.
    if (Buffer.from(account, 'utf8').toString('base64url') !== encoded || account.includes('\uFFFD')) return null
    return account || null
  } catch {
    return null
  }
}

export function validateMCPSecretReference(reference, server, kind, key) {
  const account = accountFromMCPSecretReference(reference)
  if (!account) return null
  const expected = expectedMCPSecretAccountPrefix(server, kind, key)
  if (!account.startsWith(expected)) return null
  const nonce = account.slice(expected.length)
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(nonce)) return null
  return account
}

export function readMCPKeychainSecret(account) {
  const result = spawnSync('/usr/bin/security', [
    'find-generic-password', '-a', account, '-s', MCP_SECRET_SERVICE, '-w',
  ], {
    encoding: 'utf8', timeout: 5_000, maxBuffer: 1024 * 1024,
    stdio: ['ignore', 'pipe', 'pipe'],
  })
  if (result.error || result.status !== 0) {
    throw new Error('MCP credential is unavailable in Keychain')
  }
  return String(result.stdout || '').replace(/\r?\n$/, '')
}

export function resolveMCPSecretMap(values, server, kind, readSecret = readMCPKeychainSecret) {
  const resolved = {}
  for (const [key, value] of Object.entries(values || {})) {
    if (typeof value !== 'string') throw new Error(`MCP ${kind} value must be a string`)
    if (!value.startsWith(MCP_SECRET_PREFIX)) {
      // Backward compatibility for a legacy file not yet opened by the app. The Swift store migrates
      // it to Keychain on load; agentd never writes extensions.json.
      resolved[key] = value
      continue
    }
    const account = validateMCPSecretReference(value, server, kind, key)
    if (!account) throw new Error(`MCP ${kind} credential reference is invalid`)
    resolved[key] = readSecret(account)
  }
  return resolved
}

export function loadUserExtensionsFile(file, { readSecret = readMCPKeychainSecret } = {}) {
  const cfg = JSON.parse(fs.readFileSync(file, 'utf8'))
  const servers = {}
  const networkScopes = {}
  const oauthBindings = {}
  const serverIds = {}
  const errors = []
  for (const server of (cfg.mcpServers || [])) {
    if (!server || server.enabled === false || !server.name) continue
    try {
      // Deliberately omit the SDK's `alwaysLoad` flag. Its default keeps external tools deferred
      // behind the provider's deferred tool path and MCP startup nonblocking; forcing it true adds
      // up to the connection
      // timeout to every cold first turn. Required in-process tools opt into eager loading where
      // they are declared in agentd.
      if ((server.transport || 'stdio') === 'stdio') {
        if (!server.command) continue
        servers[server.name] = {
          type: 'stdio', command: server.command, args: server.args || [],
          env: resolveMCPSecretMap(server.env, server, 'env', readSecret),
        }
      } else if (server.transport === 'http' || server.transport === 'sse') {
        if (!server.url) continue
        servers[server.name] = {
          type: server.transport, url: server.url,
          headers: resolveMCPSecretMap(server.headers, server, 'header', readSecret),
        }
      }
    } catch (error) {
      // Fail closed per server. One deleted Keychain item should not disable unrelated connections,
      // but the affected process must never receive a reference string as if it were a credential.
      const safeName = String(server.name).replace(/[\r\n\t]/g, ' ').slice(0, 160)
      errors.push({ name: safeName, message: 'MCP credentials could not be loaded securely.' })
    }
    if (servers[server.name]) {
      if (typeof server.id === 'string') serverIds[server.name] = server.id
      networkScopes[server.name] = server.networkScope === 'vpnOnly' ? 'vpnOnly' : 'public'
      if ((server.transport === 'http' || server.transport === 'sse') && server.url) {
        // Kept outside the SDK config: OAuth's Keychain record is bound to the stable app-side UUID
        // and exact endpoint, but neither field is part of Claude's McpServerConfig schema.
        oauthBindings[server.name] = {
          id: server.id, name: server.name, transport: server.transport, url: server.url,
        }
      }
    }
  }
  const plugins = (cfg.plugins || [])
    .filter((plugin) => plugin && plugin.enabled !== false && plugin.path)
    .map((plugin) => ({ type: 'local', path: plugin.path }))
  return { servers, serverIds, networkScopes, oauthBindings, plugins, errors }
}
