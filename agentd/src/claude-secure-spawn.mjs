import { spawn } from 'node:child_process'

const CLAUDE_SECRET_ENVIRONMENT = [
  'ANTHROPIC_API_KEY',
  'ANTHROPIC_AUTH_TOKEN',
  'CLAUDE_CODE_OAUTH_TOKEN',
  // Claude processes and their tools never need a credential owned by the OpenAI lane.
  'OPENAI_API_KEY',
]

const DESCRIPTOR_ENVIRONMENT = {
  apiKey: 'CLAUDE_CODE_API_KEY_FILE_DESCRIPTOR',
  oauth: 'CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR',
}

// These variables select enterprise backends or replace Anthropic's endpoint. Mechanician models
// exactly one such backend as a first-class account route — Claude-on-Vertex (FR-103) — and passes
// its selector through explicitly for that route only (see `keep` below). Every other route strips
// all of these so a conversation labeled Claude subscription / Anthropic API can never silently use
// a different provider boundary.
const UNSUPPORTED_CLAUDE_ROUTE_ENVIRONMENT = [
  'CLAUDE_CODE_USE_VERTEX',
  'CLAUDE_CODE_USE_BEDROCK',
  'CLAUDE_CODE_USE_FOUNDRY',
  'CLAUDE_CODE_USE_GATEWAY',
  'CLAUDE_CODE_USE_MANTLE',
  'CLAUDE_CODE_USE_ANTHROPIC_AWS',
  'ANTHROPIC_BASE_URL',
  'ANTHROPIC_BEDROCK_BASE_URL',
  'ANTHROPIC_BEDROCK_MANTLE_BASE_URL',
  'ANTHROPIC_VERTEX_BASE_URL',
  'ANTHROPIC_VERTEX_PROJECT_ID',
  'CLOUD_ML_REGION',
  'GOOGLE_APPLICATION_CREDENTIALS',
  'ANTHROPIC_FOUNDRY_BASE_URL',
  'ANTHROPIC_AWS_BASE_URL',
  'CLAUDE_CODE_API_BASE_URL',
]

// The only enterprise selectors Mechanician sanctions, and only for the claudeVertex route. Keep
// all four explicitly so inherited project ids or credential-file paths are scrubbed from every
// other provider lane and from local terminal/build children.
export const VERTEX_ROUTE_KEEP = [
  'CLAUDE_CODE_USE_VERTEX',
  'ANTHROPIC_VERTEX_PROJECT_ID',
  'CLOUD_ML_REGION',
  'GOOGLE_APPLICATION_CREDENTIALS',
]

/// The only enterprise selectors Mechanician sanctions for the claudeBedrock route. AWS credentials
/// themselves are NOT here and never pass through Mechanician: Bedrock resolves the ordinary AWS
/// chain (environment, `AWS_PROFILE`, SSO, instance role) inside the engine process, so all this
/// route needs is which region and which of the user's existing profiles to use.
export const BEDROCK_ROUTE_KEEP = [
  'CLAUDE_CODE_USE_BEDROCK',
  'AWS_REGION',
  'AWS_DEFAULT_REGION',
  'AWS_PROFILE',
]

/// The Bedrock selectors the Claude engine needs. Returns null without a region — an unconfigured
/// Bedrock daemon stays in a needs-setup state rather than half-activating an enterprise backend,
/// matching `vertexRouteEnvironment`.
export function bedrockRouteEnvironment({ region, profile } = {}) {
  const normalizedRegion = typeof region === 'string' ? region.trim() : ''
  const normalizedProfile = typeof profile === 'string' ? profile.trim() : ''
  if (!normalizedRegion) return null
  return {
    CLAUDE_CODE_USE_BEDROCK: '1',
    AWS_REGION: normalizedRegion,
    AWS_DEFAULT_REGION: normalizedRegion,
    ...(normalizedProfile ? { AWS_PROFILE: normalizedProfile } : {}),
  }
}

/// The anthropic-provider auth mode for a daemon environment: 'subscription' (Anthropic OAuth login),
/// 'vertex' (Claude-on-Google-Vertex via ADC), or 'apikey' (metered ANTHROPIC_API_KEY). Codex/OpenAI
/// providers do not use this. `MECHANICIAN_AUTH` carries the selected route's auth mode.
export function resolveAnthropicAuthMode(environment) {
  switch (environment.MECHANICIAN_AUTH) {
    case 'subscription': return 'subscription'
    case 'vertex': return 'vertex'
    case 'bedrock': return 'bedrock'
    default: return 'apikey'
  }
}

/// The Vertex selectors the Claude engine needs for the claudeVertex route. Returns null when no
/// project is configured (an unconfigured Vertex daemon stays in a needs-setup state rather than
/// half-activating an enterprise backend). Region defaults to 'global' — the SDK accepts it verbatim
/// via CLOUD_ML_REGION; a concrete region (e.g. us-east5) is only needed for direct REST calls.
export function vertexRouteEnvironment({ projectId, region } = {}) {
  const normalizedProject = typeof projectId === 'string' ? projectId.trim() : ''
  const normalizedRegion = typeof region === 'string' ? region.trim() : ''
  if (!normalizedProject) return null
  return {
    CLAUDE_CODE_USE_VERTEX: '1',
    ANTHROPIC_VERTEX_PROJECT_ID: normalizedProject,
    CLOUD_ML_REGION: normalizedRegion || 'global',
  }
}

// Keep Claude credentials out of the CLI environment. Claude Code reads the selected lane's secret
// from a one-shot descriptor; descendants may see its descriptor variable, but not credential bytes
// in their environment/arguments and cannot reread the drained pipe.
export function claudeCredentialFromEnvironment(environment, expectedKind) {
  const environmentName = expectedKind === 'oauth'
    ? 'CLAUDE_CODE_OAUTH_TOKEN'
    : expectedKind === 'apiKey' ? 'ANTHROPIC_API_KEY' : null
  const value = environmentName ? environment[environmentName]?.trim() : null
  if (value) return { kind: expectedKind, value }
  return null
}

export function withoutClaudeSecrets(environment) {
  const scrubbed = { ...environment }
  for (const name of CLAUDE_SECRET_ENVIRONMENT) delete scrubbed[name]
  delete scrubbed.CLAUDE_CODE_API_KEY_FILE_DESCRIPTOR
  delete scrubbed.CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR
  return scrubbed
}

export function directClaudeEnvironment(environment, { keep = [] } = {}) {
  const scrubbed = withoutClaudeSecrets(environment)
  // Mechanician owns this policy per query through `promptSuggestions`. An inherited `false`
  // silently disables suggestions for ordinary conversations, while forwarding `true` would
  // undermine a closed profile that explicitly disables them.
  delete scrubbed.CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION
  return scrubUnsupportedClaudeRoutes(scrubbed, { keep })
}

// `keep` lists sanctioned selectors to preserve (only the claudeVertex route passes VERTEX_ROUTE_KEEP;
// every other caller uses the default empty keep and strips them all).
export function scrubUnsupportedClaudeRoutes(environment, { keep = [] } = {}) {
  const keepSet = new Set(keep)
  for (const name of UNSUPPORTED_CLAUDE_ROUTE_ENVIRONMENT) {
    if (!keepSet.has(name)) delete environment[name]
  }
  return environment
}

export function claudeOAuthAccessTokenFromCredential(raw, now = Date.now()) {
  try {
    const credential = typeof raw === 'string' ? JSON.parse(raw) : raw
    const oauth = credential?.claudeAiOauth
    const token = oauth?.accessToken
    if (!token) return null
    const expiresAt = Number(oauth?.expiresAt ?? 0)
    if (expiresAt && now >= expiresAt) return null
    return token
  } catch {
    return null
  }
}

export function isClaudeSubscriptionAuthStatus(status) {
  return classifyClaudeSubscriptionAuthStatus(status).authenticated
}

// `claude auth status --json` reports third-party backends (Vertex, Bedrock, gateways) as logged in
// even when no Claude.ai subscription is active. Keep that distinction explicit: accepting only the
// boolean would silently relabel enterprise-provider traffic as a personal Claude subscription.
export function classifyClaudeSubscriptionAuthStatus(status) {
  const method = String(status?.authMethod || '').toLowerCase()
  const provider = String(status?.apiProvider || '')
  const normalizedProvider = provider.toLowerCase()
  if (status?.loggedIn !== true) {
    return { authenticated: false, reason: 'not_logged_in', method, provider }
  }
  if (method === 'third_party' ||
      (normalizedProvider && !['firstparty', 'first_party', 'anthropic'].includes(normalizedProvider))) {
    return { authenticated: false, reason: 'provider_conflict', method, provider }
  }
  if (['oauth_token', 'claude.ai', 'oauth'].includes(method)) {
    return { authenticated: true, reason: null, method, provider }
  }
  return { authenticated: false, reason: 'unsupported_auth_method', method, provider }
}

export function secureClaudeCodeSpawn(credential) {
  if (!credential?.value || !DESCRIPTOR_ENVIRONMENT[credential.kind]) return undefined

  return ({ command, args, cwd, env, signal }) => {
    const credentialFD = 3
    const childEnvironment = withoutClaudeSecrets(env)
    childEnvironment[DESCRIPTOR_ENVIRONMENT[credential.kind]] = String(credentialFD)

    // Match the SDK's normal stdin/stdout contract. Stderr is ignored unless the host elects to
    // provide its own diagnostics; leaving it as an unread pipe could deadlock a verbose CLI.
    const child = spawn(command, args, {
      cwd,
      env: childEnvironment,
      signal,
      windowsHide: true,
      // One process group per SDK launch lets agentd retire the provider's whole descendant tree.
      // Without this, a CLI helper that outlives its direct parent can retain credentials or keep
      // doing work after the app has already started a replacement provider generation.
      detached: process.platform !== 'win32',
      stdio: ['pipe', 'pipe', 'ignore', 'pipe'],
    })
    const credentialPipe = child.stdio[credentialFD]
    if (!credentialPipe) {
      child.kill()
      throw new Error('Claude credential descriptor was not created')
    }
    // EPIPE belongs to this stream, not the ChildProcess emitter. A CLI that exits before reading
    // must fail through the SDK lifecycle instead of crashing agentd with an unhandled stream error.
    credentialPipe.on('error', () => {})
    child.once('error', () => credentialPipe.destroy())
    credentialPipe.end(credential.value)
    return child
  }
}
