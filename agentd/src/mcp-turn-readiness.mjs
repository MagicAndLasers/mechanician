function boundedNames(names) {
  return [...new Set((names || []).filter((name) =>
    typeof name === 'string' && name.length > 0 && name.length <= 500))]
}

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i

export function mcpReadinessClaims(value) {
  if (!Array.isArray(value)) return []
  const byIdentity = new Map()
  const names = new Map()
  for (const entry of value) {
    if (!entry || typeof entry !== 'object') continue
    const name = typeof entry.name === 'string' ? entry.name : ''
    const changeId = typeof entry.changeId === 'string' ? entry.changeId : ''
    const source = entry.source === 'configured' || entry.source === 'providerConnector'
      ? entry.source : ''
    const serverId = typeof entry.serverId === 'string' && UUID.test(entry.serverId)
      ? entry.serverId.toLowerCase() : null
    const accountInstanceId = typeof entry.accountInstanceId === 'string'
      && UUID.test(entry.accountInstanceId) ? entry.accountInstanceId.toLowerCase() : null
    const routeIdentity = typeof entry.routeIdentity === 'string' ? entry.routeIdentity : ''
    if (!name || name.length > 500 || !changeId || changeId.length > 500 || !source
        || !accountInstanceId || !routeIdentity || routeIdentity.length > 500) continue
    if (source === 'configured' && !serverId) continue
    if (source === 'providerConnector' && entry.serverId != null) continue
    const claim = {
      name, changeId, source, ...(serverId ? { serverId } : {}),
      accountInstanceId, routeIdentity,
    }
    const identity = source === 'configured' ? `configured:${serverId}` : `connector:${name}`
    const existingNameIdentity = names.get(name)
    if (existingNameIdentity && existingNameIdentity !== identity) {
      throw new Error(`Conflicting MCP readiness sources were supplied for ${name}.`)
    }
    const existingIdentity = byIdentity.get(identity)
    if (existingIdentity
        && (existingIdentity.changeId !== claim.changeId
          || existingIdentity.accountInstanceId.toLowerCase()
            !== claim.accountInstanceId.toLowerCase()
          || existingIdentity.routeIdentity !== claim.routeIdentity)) {
      throw new Error(`Conflicting MCP readiness generations were supplied for ${name}.`)
    }
    names.set(name, identity)
    byIdentity.set(identity, claim)
  }
  return [...byIdentity.values()]
}

export function mcpReadinessClaimIdentity(claim) {
  return claim?.source === 'configured' && typeof claim?.serverId === 'string'
    ? `configured:${claim.serverId.toLowerCase()}`
    : claim?.source === 'providerConnector' && typeof claim?.name === 'string'
      ? `connector:${claim.name}` : null
}

export function missingConfiguredMcpReadinessClaims(claims, servers) {
  const configured = servers && typeof servers === 'object' ? servers : {}
  return mcpReadinessClaims(claims).filter((claim) =>
    claim.source === 'configured'
      && (!Object.prototype.hasOwnProperty.call(configured, claim.name)
        || typeof configured[claim.name]?.id !== 'string'
        || configured[claim.name].id.toLowerCase() !== claim.serverId.toLowerCase()))
}

export const DEFAULT_MCP_TURN_READINESS_TIMEOUT_MS = 30_000
export const ORDINARY_MCP_TURN_READINESS_TIMEOUT_MS = 5_000

/// Only an explicitly eager external server is allowed to gate prompt delivery. Normal SDK MCP
/// configs use the provider's nonblocking/deferred startup path so an irrelevant or unreachable
/// server cannot tax a simple first message. The provider may expose those tools directly or
/// through a callable discovery primitive; prompt guidance must not assume which one.
export function eagerMcpServerNames(servers) {
  return boundedNames(Object.entries(servers || {})
    .filter(([, config]) => config?.alwaysLoad === true)
    .map(([name]) => name))
}

/// A deferred server is normally allowed to initialize in the background. Immediately after OAuth,
/// however, the user's next fresh session must not receive its prompt until that exact server has
/// either exposed its real inventory or reached a truthful terminal failure. Union that one-shot
/// generation with the explicit eager set while filtering names against the mounted configuration.
export function mcpReadinessServerNames(servers, recentlyAuthorizedNames = []) {
  const configured = servers && typeof servers === 'object' ? servers : {}
  // Requested names are a durable security claim, not a hint derived from the current prepared
  // snapshot. Preserve an absent name so the caller fails closed instead of silently filtering
  // away the exact server whose credential just changed.
  const authorized = boundedNames(recentlyAuthorizedNames)
  return boundedNames([...authorized, ...eagerMcpServerNames(configured)])
}

/// Ordinary eager servers are a bounded best-effort latency optimization. A server promoted by a
/// just-completed OAuth flow is different: letting a prompt enter while it is still pending can
/// mint a resumable provider session whose immutable schema never contains the new tools. Fail the
/// first turn before delivery instead; the pending promotion remains for a later fresh retry.
export function mcpTurnReadinessDecision(statuses, { promotedNames = [] } = {}) {
  const promoted = new Set(boundedNames(promotedNames))
  const byName = new Map((Array.isArray(statuses) ? statuses : [])
    .filter((entry) => entry && typeof entry.name === 'string')
    .map((entry) => [entry.name, entry]))
  const unresolvedPromotedNames = [...promoted].filter((name) => {
    const entry = byName.get(name)
    return entry?.status !== 'connected'
      || !Number.isInteger(entry?.tools)
      || entry.tools <= 0
  })
  return {
    unresolvedPromotedNames,
    mayDeliverPrompt: unresolvedPromotedNames.length === 0,
  }
}

function statusSnapshot(names, statuses, authorizationStates = {}) {
  const byName = new Map(
    (Array.isArray(statuses) ? statuses : [])
      .filter((entry) => entry && typeof entry.name === 'string')
      .map((entry) => [entry.name, entry]))
  return names.map((name) => {
    const entry = byName.get(name)
    if (entry) {
      return {
        name,
        status: typeof entry.status === 'string' ? entry.status : 'unverified',
        tools: Array.isArray(entry.tools) ? entry.tools.length
          : Number.isInteger(entry.tools) && entry.tools >= 0 ? entry.tools : null,
        error: typeof entry.error === 'string' && entry.error ? entry.error : null,
      }
    }
    return {
      name,
      status: authorizationStates[name] === 'authenticated'
        ? 'authenticated' : 'unverified',
      tools: null,
      error: null,
    }
  })
}

function wait(ms, signal) {
  return new Promise((resolve, reject) => {
    let timer = null
    const cleanup = () => {
      if (timer) clearTimeout(timer)
      signal?.removeEventListener?.('abort', aborted)
    }
    const aborted = () => {
      cleanup()
      const error = signal?.reason instanceof Error
        ? signal.reason : new Error('MCP readiness was interrupted.')
      if (!error.name || error.name === 'Error') error.name = 'AbortError'
      reject(error)
    }
    if (signal?.aborted) {
      aborted()
      return
    }
    timer = setTimeout(() => {
      cleanup()
      resolve()
    }, ms)
    timer.unref?.()
    signal?.addEventListener?.('abort', aborted, { once: true })
  })
}

function reportSnapshot(callback, snapshot) {
  try { callback(snapshot) } catch {
    // Progress is advisory. A UI callback must never delay or fail prompt delivery.
  }
}

async function boundedStatusCall(stream, timeoutMs, signal) {
  const call = stream.mcpServerStatus()
  call.catch(() => {})
  let timer = null
  let aborted = null
  const boundary = new Promise((resolve, reject) => {
    aborted = () => {
      const error = signal?.reason instanceof Error
        ? signal.reason : new Error('MCP readiness was interrupted.')
      if (!error.name || error.name === 'Error') error.name = 'AbortError'
      reject(error)
    }
    if (signal?.aborted) {
      aborted()
      return
    }
    timer = setTimeout(() => resolve(null), timeoutMs)
    timer.unref?.()
    signal?.addEventListener?.('abort', aborted, { once: true })
  })
  try {
    return await Promise.race([call, boundary])
  } finally {
    if (timer) clearTimeout(timer)
    if (aborted) signal?.removeEventListener?.('abort', aborted)
  }
}

/// Wait on the REAL provider query that will receive the user's prompt when an external server has
/// explicitly opted into eager loading. This is deliberately not a second disposable query: an
/// eager MCP schema must be present when Claude initializes that session.
export async function waitForMcpTurnReadiness(
  stream,
  serverNames,
  {
    authorizationStates = {},
    promotedNames = [],
    timeoutMs = DEFAULT_MCP_TURN_READINESS_TIMEOUT_MS,
    controlTimeoutMs = 3_000,
    pollIntervalMs = 250,
    signal = null,
    now = () => Date.now(),
    onSnapshot = () => {},
  } = {},
) {
  const names = boundedNames(serverNames)
  const promoted = new Set(boundedNames(promotedNames))
  if (!names.length || typeof stream?.mcpServerStatus !== 'function') {
    const snapshot = statusSnapshot(names, [], authorizationStates)
    reportSnapshot(onSnapshot, snapshot)
    return snapshot
  }
  const deadline = now() + timeoutMs
  let last = []
  let lastSignature = null
  while (now() < deadline) {
    signal?.throwIfAborted?.()
    try {
      const result = await boundedStatusCall(
        stream, Math.max(1, Math.min(controlTimeoutMs, deadline - now())), signal)
      if (Array.isArray(result)) last = result
    } catch (error) {
      if (signal?.aborted || error?.name === 'AbortError') throw error
      // Startup can reject control calls briefly before the provider transport is initialized.
      // Retry within the same bounded readiness window.
    }
    const snapshot = statusSnapshot(names, last, authorizationStates)
    const signature = snapshot.map((entry) => `${entry.name}:${entry.status}:${entry.tools}`).join('|')
    if (signature !== lastSignature) {
      lastSignature = signature
      reportSnapshot(onSnapshot, snapshot)
    }
    if (snapshot.every((entry) => {
      if (promoted.has(entry.name) && entry.status === 'connected') {
        return Number.isInteger(entry.tools) && entry.tools > 0
      }
      return entry.status !== 'pending'
        && entry.status !== 'checking'
        && entry.status !== 'unverified'
        && entry.status !== 'authenticated'
    })) {
      return snapshot
    }
    await wait(Math.min(pollIntervalMs, Math.max(1, deadline - now())), signal)
  }
  const snapshot = statusSnapshot(names, last, authorizationStates)
  const signature = snapshot.map((entry) => `${entry.name}:${entry.status}:${entry.tools}`).join('|')
  if (signature !== lastSignature) reportSnapshot(onSnapshot, snapshot)
  return snapshot
}
