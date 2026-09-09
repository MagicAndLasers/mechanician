// Native macOS Keychain persistence for remote MCP OAuth.
//
// The Keychain item contains the complete OAuth client registration + refreshable token bundle.
// Nothing is written to extensions.json, a provider config directory, argv, or a log. Records are
// scoped to one app identity by their Keychain service and to one provider route + MCP endpoint by
// their account name and authenticated payload. Changing a server URL makes the old record inert.

import { createHash } from 'node:crypto'
import fs from 'node:fs'
import path from 'node:path'
import { spawnSync } from 'node:child_process'
import { fileURLToPath } from 'node:url'
import { credentialServices } from './credential-services.mjs'
import { mcpServerBindingDigest } from './mcp-secrets.mjs'

export const MCP_OAUTH_SERVICE = credentialServices().mcpOAuth
export const MCP_OAUTH_SCHEMA_VERSION = 1
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i
const ROUTE = /^[A-Za-z0-9._:-]{1,300}$/
const MAX_RECORD_BYTES = 1024 * 1024

function digest(value) {
  return createHash('sha256').update(value, 'utf8').digest('hex')
}

function canonicalRemoteURL(value) {
  const url = new URL(value)
  const loopback = url.hostname === '127.0.0.1' || url.hostname === 'localhost' || url.hostname === '::1'
  if (url.protocol !== 'https:' && !(url.protocol === 'http:' && loopback)) {
    throw new Error('MCP OAuth requires HTTPS (except for a loopback test server)')
  }
  url.hash = ''
  return url.toString()
}

export function mcpOAuthBinding(server, routeScope) {
  const id = typeof server?.id === 'string' ? server.id.toLowerCase() : ''
  if (!UUID.test(id)) throw new Error('MCP OAuth requires a stable server identifier')
  if ((server.transport !== 'http' && server.transport !== 'sse') || !server.url) {
    throw new Error('MCP OAuth is available only for remote servers')
  }
  if (typeof routeScope !== 'string' || !ROUTE.test(routeScope)) {
    throw new Error('MCP OAuth route scope is invalid')
  }
  const serverUrl = canonicalRemoteURL(server.url)
  const bindingDigest = mcpServerBindingDigest({ ...server, url: serverUrl })
  const routeDigest = digest(`mcp-oauth-route-v1\0${routeScope}`)
  const account = `mcp-oauth-v1|${id}|${routeDigest}`
  return Object.freeze({ account, serverId: id, serverUrl, bindingDigest, routeDigest })
}

const MODULE_DIRECTORY = path.dirname(fileURLToPath(import.meta.url))

function keychainHelperPath() {
  const candidates = [
    process.env.MECHANICIAN_KEYCHAIN_HELPER,
    path.join(path.dirname(process.execPath), 'MechanicianKeychainHelper'),
    path.resolve(MODULE_DIRECTORY, '../../app/.build/debug/MechanicianKeychainHelper'),
    path.resolve(MODULE_DIRECTORY, '../../app/.build/release/MechanicianKeychainHelper'),
  ].filter(Boolean)
  return candidates.find((candidate) => path.isAbsolute(candidate)
    && fs.existsSync(candidate) && fs.statSync(candidate).isFile()) || null
}

function defaultKeychainHelper(operation, service, account, input) {
  const helper = keychainHelperPath()
  if (!helper) return { status: null, error: new Error('native Keychain helper is unavailable') }
  return spawnSync(helper, [operation, service, account], {
    encoding: 'utf8', input, timeout: 10_000, maxBuffer: MAX_RECORD_BYTES,
    stdio: ['pipe', 'pipe', 'pipe'],
  })
}

function fixedKeychainError(operation) {
  return new Error(`MCP OAuth credentials could not be ${operation} in the macOS Keychain`)
}

function isMissing(result) { return result?.status === 44 }

export function createMcpOAuthKeychain({
  service = MCP_OAUTH_SERVICE,
  runHelper = defaultKeychainHelper,
} = {}) {
  if (typeof service !== 'string' || !/^[A-Za-z0-9._-]{1,200}$/.test(service)) {
    throw new Error('MCP OAuth Keychain service is invalid')
  }

  function read(binding) {
    const result = runHelper('read', service, binding.account)
    if (result?.error) throw fixedKeychainError('read')
    if (result?.status !== 0) {
      if (isMissing(result)) return null
      throw fixedKeychainError('read')
    }
    const raw = String(result.stdout || '')
    if (!raw || Buffer.byteLength(raw, 'utf8') > MAX_RECORD_BYTES) {
      throw fixedKeychainError('read')
    }
    let record
    try { record = JSON.parse(raw) } catch { throw fixedKeychainError('read') }
    if (!record || record.schemaVersion !== MCP_OAUTH_SCHEMA_VERSION
        || record.serverId !== binding.serverId
        || record.serverUrl !== binding.serverUrl
        || record.bindingDigest !== binding.bindingDigest
        || record.routeDigest !== binding.routeDigest) {
      // A stale URL, copied item, or item from another route must never yield a bearer token.
      return null
    }
    return record
  }

  function write(binding, state) {
    const record = {
      ...state,
      schemaVersion: MCP_OAUTH_SCHEMA_VERSION,
      serverId: binding.serverId,
      serverUrl: binding.serverUrl,
      bindingDigest: binding.bindingDigest,
      routeDigest: binding.routeDigest,
    }
    const raw = JSON.stringify(record)
    if (Buffer.byteLength(raw, 'utf8') > MAX_RECORD_BYTES) throw fixedKeychainError('saved')
    const result = runHelper('write', service, binding.account, raw)
    if (result?.error || result?.status !== 0) throw fixedKeychainError('saved')
    return record
  }

  function remove(binding) {
    const result = runHelper('delete', service, binding.account)
    // The native helper maps errSecItemNotFound to 44. Clear Auth is idempotent, while a
    // locked/denied Keychain remains a visible failure rather than a false success.
    if (result?.error || (result?.status !== 0 && !isMissing(result))) {
      throw fixedKeychainError('removed')
    }
  }

  return Object.freeze({ service, read, write, remove })
}
