function safeName(value) {
  return String(value || '').replace(/[\r\n\t]/g, ' ').slice(0, 160)
}

/// Report only durable/local readiness for configured MCP servers. This deliberately does not
/// create a Claude query: a panel refresh must never compete with the real provider turn that owns
/// the server connection and tool schema.
export function configuredMcpStatusPayload(loaded = {}) {
  const rows = new Map()
  const authorizationStates = loaded.authorizationStates || {}
  for (const name of Object.keys(loaded.servers || {})) {
    const authorization = authorizationStates[name]
    const status = authorization === 'authenticated'
      ? 'authenticated'
      : authorization === 'needs-auth'
        ? 'needs-auth'
        : authorization === 'unavailable'
          ? 'failed'
          : 'configured'
    rows.set(name, {
      name: safeName(name),
      status,
      error: status === 'failed'
        ? 'MCP OAuth credentials could not be loaded from the macOS Keychain.'
        : null,
      tools: null,
      version: null,
      scope: loaded.networkScopes?.[name] || null,
      foreign: false,
    })
  }
  for (const unavailable of loaded.unavailable || []) {
    if (!unavailable?.name) continue
    rows.set(unavailable.name, {
      name: safeName(unavailable.name),
      status: 'failed',
      error: unavailable.message || 'This MCP server is not currently reachable.',
      tools: null,
      version: null,
      scope: 'vpnOnly',
      foreign: false,
    })
  }
  for (const error of loaded.errors || []) {
    if (!error?.name) continue
    rows.set(error.name, {
      name: safeName(error.name),
      status: 'failed',
      error: error.message || 'MCP credentials could not be loaded securely.',
      tools: null,
      version: null,
      scope: loaded.networkScopes?.[error.name] || null,
      foreign: false,
    })
  }
  return [...rows.values()].sort((left, right) => left.name.localeCompare(right.name))
}
