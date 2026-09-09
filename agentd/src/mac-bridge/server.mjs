#!/usr/bin/env node
// Mac Bridge — this Mac's own capabilities, offered to any MCP client over an authenticated
// loopback endpoint.
//
// Run:  node agentd/src/mac-bridge/server.mjs --port 7777
//
// Bound to 127.0.0.1 only. That is not the access control — any local process can reach loopback —
// it just keeps the surface off the network while OAuth plus a human consent step decide which
// client may drive the machine.

import { randomUUID } from 'node:crypto'
import readline from 'node:readline'
import express from 'express'

import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js'
import { StreamableHTTPServerTransport } from '@modelcontextprotocol/sdk/server/streamableHttp.js'
import { mcpAuthRouter } from '@modelcontextprotocol/sdk/server/auth/router.js'
import { requireBearerAuth } from '@modelcontextprotocol/sdk/server/auth/middleware/bearerAuth.js'
import { z } from 'zod'

import { MacBridgeOAuthProvider } from './oauth.mjs'
import { askOnDevice, listShortcuts, runShortcut } from './tools.mjs'

const port = Number(
  process.argv.includes('--port')
    ? process.argv[process.argv.indexOf('--port') + 1]
    : process.env.MAC_BRIDGE_PORT || 7777,
)
const issuer = new URL(`http://127.0.0.1:${port}`)

// Tests and CI cannot click a consent page. This is the ONLY way to bypass the human, it is opt-in
// through the environment, and it announces itself loudly so it can never be mistaken for normal.
const autoApprove = process.env.MAC_BRIDGE_AUTO_APPROVE === '1'

// Consent is decided by the human in Mechanician, not here. This process is the resource server;
// it must never be the thing that grants access to itself. The app owns us as a child process, so
// requests go out on stdout as NDJSON and decisions come back on stdin — the same shape agentd
// already uses, so there is no second IPC mechanism to reason about.
const pendingConsent = new Map()
/// Clients that have been approved, for the app's "what can reach my Mac right now" list.
const approvedClients = new Map()

function send(message) {
  process.stdout.write(`${JSON.stringify(message)}\n`)
}

function publishClients() {
  send({ type: 'clients', clients: [...approvedClients.values()] })
}

const CONSENT_TIMEOUT_MS = 120_000

async function requestConsent({ client, scopes }) {
  if (autoApprove) return true
  const requestId = randomUUID()
  send({
    type: 'consent_request',
    id: requestId,
    client: { id: client.client_id, name: client.client_name || client.client_id },
    scopes,
  })
  return await new Promise((resolve) => {
    // An unanswered request must not hold an HTTP handler open forever. Timing out DENIES: the
    // safe default when nobody said yes is no.
    const timer = setTimeout(() => {
      if (pendingConsent.delete(requestId)) {
        send({ type: 'consent_expired', id: requestId })
        resolve(false)
      }
    }, CONSENT_TIMEOUT_MS)
    timer.unref?.()
    pendingConsent.set(requestId, (approved) => {
      clearTimeout(timer)
      if (approved) {
        approvedClients.set(client.client_id, {
          id: client.client_id,
          name: client.client_name || client.client_id,
          approvedAt: new Date().toISOString(),
        })
        publishClients()
      }
      resolve(approved)
    })
  })
}

/// Decisions and revocations from the app.
readline.createInterface({ input: process.stdin }).on('line', (line) => {
  let message
  try { message = JSON.parse(line) } catch { return }
  if (message?.type === 'consent_decision') {
    const resolve = pendingConsent.get(message.id)
    if (!resolve) return
    pendingConsent.delete(message.id)
    resolve(message.approved === true)
    return
  }
  if (message?.type === 'revoke' && message.clientId) {
    // Revoking is not cosmetic: drop the client's tokens so its next call fails, not just its row.
    provider.revokeClient(message.clientId)
    approvedClients.delete(message.clientId)
    publishClients()
  }
})

const provider = new MacBridgeOAuthProvider({ requestConsent })

function buildMcpServer() {
  const server = new McpServer(
    { name: 'mechanician-mac-bridge', version: '0.1.0' },
    { capabilities: { tools: {} } },
  )

  server.registerTool('list_shortcuts', {
    title: 'List Shortcuts',
    description:
      "List the Shortcuts available on this Mac. These are the user's own automations and are the "
      + 'set of names accepted by run_shortcut.',
    inputSchema: {},
  }, async () => {
    const names = await listShortcuts()
    return {
      content: [{
        type: 'text',
        text: names.length ? names.join('\n') : 'No Shortcuts are installed on this Mac.',
      }],
    }
  })

  server.registerTool('run_shortcut', {
    title: 'Run a Shortcut',
    description:
      "Run one of this Mac's Shortcuts by name and return its output. The name must come from "
      + 'list_shortcuts. Shortcuts can have real side effects, so prefer reading before acting.',
    inputSchema: {
      name: z.string().describe('Exact shortcut name, as returned by list_shortcuts.'),
      input: z.string().optional().describe('Optional text input passed to the shortcut.'),
    },
  }, async ({ name, input }) => ({
    content: [{ type: 'text', text: await runShortcut({ name, input }) }],
  }))

  server.registerTool('ask_on_device', {
    title: 'Ask the on-device model',
    description:
      "Answer a self-contained prompt with Apple's on-device foundation model. Runs locally: no "
      + 'network, no cost, nothing leaves this Mac. Good for classification, extraction, short '
      + 'rewrites and triage; it is a small model, so do not use it for long reasoning.',
    inputSchema: {
      prompt: z.string().describe('A self-contained instruction or question.'),
    },
  }, async ({ prompt }) => ({
    content: [{ type: 'text', text: await askOnDevice({ prompt }) }],
  }))

  return server
}

const app = express()
app.use(express.json())

app.use(mcpAuthRouter({
  provider,
  issuerUrl: issuer,
  resourceName: "This Mac's Shortcuts and on-device model",
  scopesSupported: ['mac.read', 'mac.run'],
}))

const bearer = requireBearerAuth({ verifier: provider })

// Stateless: a fresh server and transport per request, so one client's session can never observe
// another's. The bridge holds no conversation state worth reusing.
app.post('/mcp', bearer, async (req, res) => {
  const server = buildMcpServer()
  const transport = new StreamableHTTPServerTransport({ sessionIdGenerator: undefined })
  res.on('close', () => { transport.close(); server.close() })
  await server.connect(transport)
  await transport.handleRequest(req, res, req.body)
})

for (const method of ['get', 'delete']) {
  app[method]('/mcp', bearer, (_req, res) => {
    res.status(405).json({ error: 'method_not_allowed' })
  })
}

const listener = app.listen(port, '127.0.0.1', () => {
  // stdout is a protocol channel now, so status is a message rather than prose.
  send({ type: 'bridge_ready', url: `${issuer}mcp`, port, autoApprove })
})

for (const signal of ['SIGINT', 'SIGTERM']) {
  process.on(signal, () => { listener.close(() => process.exit(0)) })
}
