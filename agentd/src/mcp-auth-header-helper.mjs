#!/usr/bin/env node
// Claude Code headersHelper for Mechanician-owned MCP OAuth records.
//
// stdout is a credential channel consumed directly by Claude Code. Never log from this process.
// The helper re-resolves the configured server and Keychain binding on every connection/reconnect,
// refreshes a standards-based token when needed, and emits only the Authorization header JSON.

import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

import { createMcpOAuthManager } from './mcp-oauth.mjs'

const MAX_EXTENSIONS_BYTES = 16 * 1024 * 1024

function configuredServer(environment, readFile = fs.readFileSync) {
  const name = environment.CLAUDE_CODE_MCP_SERVER_NAME
  const connectedURL = environment.CLAUDE_CODE_MCP_SERVER_URL
  if (typeof name !== 'string' || !name || name.length > 500 || typeof connectedURL !== 'string') {
    throw new Error('invalid MCP helper context')
  }
  const support = environment.MECHANICIAN_SUPPORT_DIR
    || path.join(os.homedir(), 'Library', 'Application Support', 'Mechanician')
  const file = path.join(support, 'extensions.json')
  const raw = readFile(file, 'utf8')
  if (Buffer.byteLength(raw, 'utf8') > MAX_EXTENSIONS_BYTES) throw new Error('extensions config is too large')
  const payload = JSON.parse(raw)
  const server = (payload.mcpServers || []).find((candidate) =>
    candidate && candidate.enabled !== false && candidate.name === name
      && (candidate.transport === 'http' || candidate.transport === 'sse'))
  if (!server) throw new Error('configured MCP server is unavailable')
  // Claude supplies the URL of the server whose helper it is invoking. Exact canonical matching
  // prevents a copied helper field from asking for another server's Keychain record.
  const expected = new URL(server.url).toString()
  const actual = new URL(connectedURL).toString()
  if (expected !== actual) throw new Error('MCP helper endpoint mismatch')
  return { id: server.id, name: server.name, transport: server.transport, url: server.url }
}

export async function resolveMcpOAuthHeaders({
  environment = process.env,
  readFile = fs.readFileSync,
  manager,
} = {}) {
  const routeScope = environment.MECHANICIAN_MCP_OAUTH_ROUTE_SCOPE
  if (typeof routeScope !== 'string' || !routeScope) throw new Error('missing MCP OAuth route scope')
  const server = configuredServer(environment, readFile)
  const oauth = manager || createMcpOAuthManager({ routeScope })
  const token = await oauth.accessToken(server, { allowRefresh: false })
  if (!token) throw new Error('MCP OAuth authorization is unavailable')
  return { Authorization: `Bearer ${token}` }
}

const isMain = process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)
if (isMain) {
  try {
    process.stdout.write(JSON.stringify(await resolveMcpOAuthHeaders()))
  } catch {
    process.exitCode = 1
  }
}
