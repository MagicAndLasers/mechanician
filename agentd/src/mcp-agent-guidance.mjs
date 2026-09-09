const MCP_CONNECTIONS_APPEND =
  'External MCP connections are configured for this turn. The callable tool list is the source ' +
  'of truth. When a relevant mcp__… tool is present, call it directly. When it is absent, use a ' +
  'tool-discovery primitive only if that primitive is itself present in the callable tool list. ' +
  'Never try to invoke a tool name through the Skill tool. Before saying that an integration is ' +
  'unavailable, check the callable tools and attempt the relevant direct tool; report the actual ' +
  'authentication or connection error instead of inferring a harness limitation.'

export const MCP_BOUNDARY_APPEND =
  'MCP connection boundary: Mechanician exposes a configured server only through tools in this ' +
  'turn’s callable tool list. Prefer a direct mcp__… call for a single lookup, and do not spawn a ' +
  'subagent merely to work around a supposedly missing tool. Use a discovery tool only when it is ' +
  'actually callable. If no relevant direct or discovery tool exists, or the server is reported ' +
  'as needing authentication or unavailable, say that plainly. For a narrow document question, ' +
  'prefer search excerpts or a section-scoped fetch before retrieving an entire page; fetch the ' +
  'full page only when the task actually needs it. Do not search ~/.claude.json, ' +
  'Keychain, provider credential files, process command lines, or other clients’ configuration, ' +
  'and do not send raw HTTP requests with credentials as a substitute for the missing MCP tool.'

function safeMCPPromptIdentifier(value) {
  return String(value || '').replace(/[^a-zA-Z0-9._:-]+/g, '-').slice(0, 100)
    || 'unnamed-server'
}

export function mcpConnectionsAppend(connections) {
  const summary = connections.map((connection) => {
    const name = safeMCPPromptIdentifier(connection.name)
    const state = ['authorizing', 'authenticated', 'checking', 'connected', 'needs-auth', 'failed',
      'vpn-unavailable', 'credentials-unavailable', 'unverified'].includes(connection.status)
      ? connection.status : 'unverified'
    const tools = state === 'connected' && Number.isInteger(connection.tools)
      ? `:${Math.max(0, connection.tools)}-tools` : ''
    return `${name}=${state}${tools}`
  }).join(', ')
  return MCP_CONNECTIONS_APPEND +
    ` Configured server readiness for this provider lane: ${summary}. ` +
    'If a server is needs-auth, tell the user immediately that it is configured but not ' +
    'authenticated and direct them to Extensions → MCP Servers. If it is failed, unavailable, ' +
    'or has zero tools, say that plainly instead of searching other clients or credentials.'
}
