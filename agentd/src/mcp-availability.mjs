// VPN-scoped MCP reachability. Public servers are never preflighted: the SDK owns their normal
// connection/auth lifecycle. A VPN-only remote gets one short, credential-free HEAD request; any
// HTTP response proves the route is reachable, while a network failure omits only that server.

function safeServerName(value) {
  return String(value || '').replace(/[\r\n\t]/g, ' ').slice(0, 160)
}

export function createMCPAvailabilityChecker({
  fetchImpl = globalThis.fetch,
  timeoutMs = 2_000,
  // A reachable corporate route is stable enough to reuse across several turns. The old 30-second
  // TTL made ordinary pauses between prompts pay the full VPN HEAD timeout again. Failures expire
  // quickly so reconnecting the VPN repairs the next turn without a manual reload. `cacheTTLms`
  // remains as a test/backward-compatible override for both directions.
  cacheTTLms,
  reachableCacheTTLms = cacheTTLms ?? 5 * 60_000,
  unreachableCacheTTLms = cacheTTLms ?? 15_000,
  now = () => Date.now(),
} = {}) {
  const cache = new Map()
  const inFlight = new Map()

  async function fetchReachability(url) {
    const cached = cache.get(url)
    if (cached && cached.expiresAt > now()) return cached.reachable
    if (inFlight.has(url)) return inFlight.get(url)

    const request = (async () => {
      const controller = new AbortController()
      const timeout = setTimeout(() => controller.abort(), timeoutMs)
      timeout.unref?.()
      let reachable = false
      try {
        const target = new URL(url)
        if (target.protocol !== 'https:') return false
        // Deliberately omit configured MCP headers. A 401/403/405 still proves VPN reachability,
        // without putting a bearer token on a synthetic probe request.
        const response = await fetchImpl(target, {
          method: 'HEAD',
          redirect: 'manual',
          headers: { Accept: 'application/json' },
          signal: controller.signal,
        })
        reachable = !Number.isInteger(response?.status) || response.status < 500
        return reachable
      } catch {
        return false
      } finally {
        clearTimeout(timeout)
        cache.set(url, {
          reachable,
          expiresAt: now() + (reachable ? reachableCacheTTLms : unreachableCacheTTLms),
        })
        inFlight.delete(url)
      }
    })()
    inFlight.set(url, request)
    return request
  }

  async function filter(loaded) {
    const servers = loaded?.servers || {}
    const scopes = loaded?.networkScopes || {}
    const available = {}
    const unavailable = []

    await Promise.all(Object.entries(servers).map(async ([name, server]) => {
      if (scopes[name] !== 'vpnOnly' || !['http', 'sse'].includes(server?.type)) {
        available[name] = server
        return
      }
      if (await fetchReachability(server.url)) {
        available[name] = server
        return
      }
      unavailable.push({
        name: safeServerName(name),
        message: 'VPN-only MCP server unavailable — connect to your corporate VPN.',
      })
    }))

    unavailable.sort((a, b) => a.name.localeCompare(b.name))
    return { ...loaded, servers: available, unavailable }
  }

  return { filter, clearCache: () => cache.clear() }
}
