import assert from 'node:assert/strict'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { test } from 'node:test'

import { query } from '@anthropic-ai/claude-agent-sdk'
import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js'
import { createMcpExpressApp } from '@modelcontextprotocol/sdk/server/express.js'
import { StreamableHTTPServerTransport } from '@modelcontextprotocol/sdk/server/streamableHttp.js'
import * as z from 'zod/v4'

import { createMcpOAuthKeychain } from '../src/mcp-oauth-keychain.mjs'
import { createMcpOAuthManager } from '../src/mcp-oauth.mjs'

const here = path.dirname(fileURLToPath(import.meta.url))
const repo = path.resolve(here, '../..')
const nativeHelper = path.join(repo, 'app/.build/debug/MechanicianKeychainHelper')
const claude = path.join(
  repo, 'agentd/node_modules/@anthropic-ai/claude-agent-sdk-darwin-arm64/claude')
const headerHelper = path.join(repo, 'agentd/src/mcp-auth-header-helper.mjs')

function shellQuote(value) {
  return `'${String(value).replaceAll("'", `'"'"'`)}'`
}

async function startAuthenticatedMcpServer() {
  const app = createMcpExpressApp()
  let authorizedRequests = 0
  app.use((request, response, next) => {
    if (request.headers.authorization !== 'Bearer mount-test-token') {
      response.status(401).json({ error: 'unauthorized' })
      return
    }
    authorizedRequests++
    next()
  })
  app.post('/mcp', async (request, response) => {
    const server = new McpServer({ name: 'mount-test', version: '1.0.0' })
    server.registerTool(
      'ping',
      { description: 'A read-only mount test.', inputSchema: { value: z.string().optional() } },
      async ({ value }) => ({ content: [{ type: 'text', text: value || 'pong' }] }),
    )
    const transport = new StreamableHTTPServerTransport({ sessionIdGenerator: undefined })
    response.on('close', () => {
      transport.close().catch(() => {})
      server.close().catch(() => {})
    })
    await server.connect(transport)
    await transport.handleRequest(request, response, request.body)
  })
  const listener = await new Promise((resolve, reject) => {
    const next = app.listen(0, '127.0.0.1', () => resolve(next))
    next.once('error', reject)
  })
  const address = listener.address()
  return {
    url: `http://127.0.0.1:${address.port}/mcp`,
    authorizedRequests: () => authorizedRequests,
    close: () => new Promise((resolve) => listener.close(resolve)),
  }
}

test('authenticated Keychain MCP mounts tools in the bundled Claude runtime', {
  timeout: 45_000,
  skip: process.platform !== 'darwin'
    || process.env.MECHANICIAN_RUN_MCP_MOUNT_INTEGRATION !== '1',
}, async () => {
  assert.equal(fs.existsSync(nativeHelper), true, 'build MechanicianKeychainHelper first')
  assert.equal(fs.existsSync(claude), true, 'locked Claude runtime is unavailable')
  const fixture = await startAuthenticatedMcpServer()
  const support = fs.mkdtempSync(path.join(os.tmpdir(), 'mechanician-mcp-mount-'))
  const service = `ai.mechanician.mcp-oauth.mount-test-${process.pid}`
  const routeScope = 'anthropic:subscription:builtin'
  const server = {
    id: '7f661a72-4885-42ad-bce1-242b6741d88a',
    name: 'VICE',
    transport: 'http',
    url: fixture.url,
  }
  const environment = {
    ...process.env,
    MECHANICIAN_SUPPORT_DIR: support,
    MECHANICIAN_MCP_OAUTH_SERVICE: service,
    MECHANICIAN_MCP_OAUTH_ROUTE_SCOPE: routeScope,
    MECHANICIAN_KEYCHAIN_HELPER: nativeHelper,
    CLAUDE_CONFIG_DIR:
      path.join(os.homedir(), 'Library/Application Support/Mechanician/claude'),
    CLAUDE_SECURESTORAGE_CONFIG_DIR:
      path.join(os.homedir(), 'Library/Application Support/Mechanician/claude'),
  }
  const keychain = createMcpOAuthKeychain({ service })
  const manager = createMcpOAuthManager({
    routeScope,
    keychain,
    headerHelperCommand: `${shellQuote(process.execPath)} ${shellQuote(headerHelper)}`,
  })
  const binding = manager.bindingFor(server)
  keychain.write(binding, {
    flow: 'mount-test',
    tokens: { access_token: 'mount-test-token', token_type: 'Bearer' },
    tokensObtainedAt: Date.now(),
  })
  fs.writeFileSync(path.join(support, 'extensions.json'), JSON.stringify({
    mcpServers: [{ ...server, enabled: true, headers: {} }],
  }), { mode: 0o600 })

  let probe
  let releaseInput
  let pump
  try {
    const loaded = {
      servers: {
        VICE: { type: 'http', url: fixture.url, headers: {}, alwaysLoad: true },
      },
      oauthBindings: { VICE: server },
      errors: [],
    }
    await manager.applyAuthorization(loaded)
    async function* idleInput() {
      await new Promise((resolve) => { releaseInput = resolve })
    }
    probe = query({
      prompt: idleInput(),
      options: {
        cwd: repo,
        model: 'claude-sonnet-4-5',
        env: environment,
        pathToClaudeCodeExecutable: claude,
        settingSources: [],
        permissionMode: 'default',
        includePartialMessages: false,
        settings: { enableWorkflows: true },
        mcpServers: loaded.servers,
      },
    })
    pump = (async () => {
      try {
        for await (const _event of probe) { /* drain */ }
      } catch { /* status assertion below is authoritative */ }
    })()
    let vice
    const deadline = Date.now() + 20_000
    while (Date.now() < deadline) {
      const statuses = await probe.mcpServerStatus()
      vice = statuses.find((candidate) => candidate.name === 'VICE')
      if (vice?.status !== 'pending') break
      await new Promise((resolve) => setTimeout(resolve, 250))
    }
    assert.equal(vice?.status, 'connected')
    assert.equal(vice?.tools?.length, 1)
    assert.equal(fixture.authorizedRequests() > 0, true)
  } finally {
    releaseInput?.()
    try { await probe?.return?.() } catch {}
    try { await pump } catch {}
    keychain.remove(binding)
    fs.rmSync(support, { recursive: true, force: true })
    await fixture.close()
  }
})
