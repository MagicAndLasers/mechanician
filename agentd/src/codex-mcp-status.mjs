// Translate Codex's view of the MCP servers into the status contract the app already speaks.
//
// Mirror, do not invent: `mcp_status_result.servers[]` and its status vocabulary
// (connected | authenticated | needs-auth | failed | pending | disabled) are validated strictly on
// the app side and already drive the Extensions panel and the toolbar's attention dot. Codex has a
// different vocabulary — McpServerStartupState {starting, ready, failed, cancelled} plus
// McpAuthStatus {unsupported, notLoggedIn, bearerToken, oAuth} — and this is the only place the two
// meet. Both Codex enums are pinned in the schema lock, so a rename fails the build rather than
// quietly degrading every row to "unknown".

/// Codex's transport errors carry the full Rust type path — a real one measured here ran past 300
/// characters of `rmcp::transport::worker::WorkerTransport<...>` before reaching the part a person
/// can act on. These land in a panel row, so keep the readable head and drop the machinery.
const ERROR_LIMIT = 200

function boundedError(message, fallback) {
  const text = String(message ?? '').replace(/\s+/g, ' ').trim()
  if (!text) return fallback
  return text.length > ERROR_LIMIT ? `${text.slice(0, ERROR_LIMIT - 1)}…` : text
}

/**
 * @param {Array<object>} configured  the credentials-scope payload (config + Keychain), which is
 *   authoritative about WHICH servers exist and already works on any lane.
 * @param {object} live
 * @param {Array<object>} [live.listData]     mcpServerStatus/list `data`
 * @param {Map<string, object>} [live.startup] latest mcpServer/startupStatus/updated per server
 * @param {Array<{name: string, reason: string}>} [live.unsupported] servers Codex cannot be given
 * @returns {Array<object>} servers[] in the app's contract
 */
export function mergeCodexLiveStatus(configured, { listData = [], startup = new Map(), unsupported = [] } = {}) {
  const blocked = new Map(unsupported.map((item) => [item.name, item.reason]))
  const byName = new Map()
  for (const server of listData) {
    if (server?.name) byName.set(server.name, server)
  }

  return (configured || []).map((entry) => {
    // A server we could not hand to Codex is not "unknown" — we know exactly why it is absent, and
    // saying so is the difference between a fixable message and a mystery.
    if (blocked.has(entry.name)) {
      return { ...entry, status: 'failed', error: boundedError(blocked.get(entry.name)), tools: null }
    }

    const observed = byName.get(entry.name)
    const startupState = startup.get(entry.name)
    if (!observed && !startupState) {
      // Configured for this lane but Codex has not reported on it yet.
      return { ...entry, status: 'pending', tools: null }
    }

    // A startup notification is newer than the list snapshot, so it wins where they disagree.
    if (startupState) {
      switch (startupState.status) {
        case 'failed':
          // The one failure a user can act on directly, and Codex names it explicitly.
          if (startupState.failureReason === 'reauthenticationRequired') {
            return { ...entry, status: 'needs-auth', tools: null, error: null }
          }
          return {
            ...entry,
            status: 'failed',
            tools: null,
            error: boundedError(startupState.error, 'The server failed to start.'),
          }
        case 'cancelled':
          return { ...entry, status: 'failed', tools: null, error: 'Startup was cancelled.' }
        case 'starting':
          return { ...entry, status: 'pending', tools: null }
        case 'ready':
          break
        default:
          break
      }
    }

    if (observed?.authStatus === 'notLoggedIn') {
      return { ...entry, status: 'needs-auth', tools: null, error: null }
    }

    const tools = observed?.tools ? Object.keys(observed.tools).length : null
    if (observed?.serverInfo || startupState?.status === 'ready') {
      return { ...entry, status: 'connected', tools, error: null }
    }
    // Listed, but no handshake yet and nothing has failed.
    return { ...entry, status: 'pending', tools: null }
  })
}

/// Keeps only the newest notification per server. Codex emits one per state transition, and a
/// `ready` that arrives after a `starting` must not be overwritten by re-reading the older one.
export function recordCodexStartupStatus(store, notification) {
  const name = notification?.name ?? notification?.serverName
  if (!name) return store
  store.set(name, {
    status: notification.status,
    error: notification.error ?? null,
    failureReason: notification.failureReason ?? null,
  })
  return store
}

/// Terminal activation result for the server whose credential just changed. This release models
/// tool-bearing MCP servers: an empty or absent inventory cannot prove that the agent can use the
/// newly authenticated connection, so both remain pending until the bounded caller fails closed.
export function codexMcpActivationState(name, {
  listData = [], startup = new Map(), unsupported = [],
} = {}) {
  const blocked = (unsupported || []).find((item) => item?.name === name)
  if (blocked) return { terminal: true, ok: false, status: 'failed', error: blocked.reason }
  const observed = (listData || []).find((item) => item?.name === name)
  const state = startup?.get?.(name)
  if (state?.status === 'failed') {
    return {
      terminal: true,
      ok: false,
      status: state.failureReason === 'reauthenticationRequired' ? 'needs-auth' : 'failed',
      error: state.error || null,
    }
  }
  if (state?.status === 'cancelled') {
    return { terminal: true, ok: false, status: 'failed', error: 'Startup was cancelled.' }
  }
  if (observed?.authStatus === 'notLoggedIn') {
    return { terminal: true, ok: false, status: 'needs-auth', error: null }
  }
  const tools = observed?.tools && typeof observed.tools === 'object'
    ? Object.keys(observed.tools).length : 0
  if ((observed?.serverInfo || state?.status === 'ready') && tools > 0) {
    return {
      terminal: true,
      ok: true,
      status: 'connected',
      tools,
      error: null,
    }
  }
  return { terminal: false, ok: false, status: 'pending', tools: null, error: null }
}
