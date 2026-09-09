// Serialize changes to the MCP configuration seen by Codex App Server.
//
// A Codex thread fixes its MCP tool set when the thread is opened, while credential-backed MCP
// servers also depend on environment variables fixed when App Server is spawned.  Configuration
// changes therefore need one ordered boundary shared by the Extensions UI, OAuth completion, idle
// prewarming, and real turns.  This small coordinator owns only that ordering; agentd supplies the
// provider-specific apply/reload/restart operation so the state machine remains directly testable.

import fs from 'node:fs'
import path from 'node:path'
import { createHash, randomUUID } from 'node:crypto'

export const CODEX_MCP_CREDENTIAL_GENERATION_FILE = '.mechanician-mcp-credentials.generation'
const CODEX_SESSION_PREFIX = 'codex-tools:'
const CODEX_MCP_SESSION_PROOF = ':mechanician-mcp:'
const CODEX_TOOL_PROFILE_SESSION_PROOF = ':mechanician-profile:'

export function codexMcpCredentialGenerationPath(codexHome) {
  return path.join(codexHome, CODEX_MCP_CREDENTIAL_GENERATION_FILE)
}

function readCredentialGenerations(codexHome) {
  let raw = ''
  try { raw = fs.readFileSync(codexMcpCredentialGenerationPath(codexHome), 'utf8').trim() }
  catch { return { revision: '', servers: {} } }
  try {
    const parsed = JSON.parse(raw)
    if (parsed?.schemaVersion !== 1 || typeof parsed.revision !== 'string'
        || !parsed.servers || typeof parsed.servers !== 'object'
        || Array.isArray(parsed.servers)) throw new Error('invalid marker')
    const servers = {}
    for (const [id, generation] of Object.entries(parsed.servers)) {
      if (/^[0-9a-f-]{36}$/i.test(id) && typeof generation === 'string' && generation) {
        servers[id.toLowerCase()] = generation
      }
    }
    return { revision: parsed.revision, servers }
  } catch {
    // Compatibility with the first marker dogfood, which stored one opaque generation line.
    return { revision: raw, servers: {} }
  }
}

export function readCodexMcpCredentialGeneration(codexHome, serverId = null) {
  const record = readCredentialGenerations(codexHome)
  return serverId ? record.servers[String(serverId).toLowerCase()] || '' : record.revision
}

function canonicalJSON(value) {
  if (Array.isArray(value)) return `[${value.map(canonicalJSON).join(',')}]`
  if (value && typeof value === 'object') {
    return `{${Object.keys(value).sort().map((key) =>
      `${JSON.stringify(key)}:${canonicalJSON(value[key])}`).join(',')}}`
  }
  return JSON.stringify(value)
}

/// Read the exact file bytes for optimistic write protection, while deriving process/thread
/// identity only from provider-visible MCP schema. extensions.json also carries UI registries and
/// crash-recovery ledgers; formatting or resolving one of those must not churn a Codex process or
/// invalidate a freshly-created thread whose MCP tools did not change.
export function codexMcpExtensionsSchemaSnapshot(extensionsFile) {
  let bytes
  try { bytes = fs.readFileSync(extensionsFile) } catch { bytes = Buffer.from('') }
  let parsed = null
  try { parsed = JSON.parse(bytes.toString('utf8')) } catch {}
  const servers = Array.isArray(parsed?.mcpServers) ? parsed.mcpServers : []
  const providerConfigurationRevision = typeof parsed?.providerConfigurationRevision === 'string'
    ? parsed.providerConfigurationRevision : null
  const schema = canonicalJSON({ providerConfigurationRevision, mcpServers: servers })
  return {
    rawFingerprint: createHash('sha256').update(bytes).digest('hex'),
    schemaFingerprint: createHash('sha256').update(schema).digest('hex'),
    servers,
    providerConfigurationRevision,
  }
}

/// Publish only a random/non-secret generation identity. OAuth tokens remain exclusively in
/// Codex's keyring; sibling daemons use this marker to learn that their process/thread MCP view is
/// stale even when extensions.json and injected environment variables are byte-identical.
export function publishCodexMcpCredentialGeneration(
  codexHome,
  changeId = randomUUID(),
  serverId = null,
) {
  fs.mkdirSync(codexHome, { recursive: true })
  const target = codexMcpCredentialGenerationPath(codexHome)
  const temporary = `${target}.${process.pid}.${randomUUID()}.tmp`
  let descriptor = null
  try {
    const current = readCredentialGenerations(codexHome)
    if (serverId) current.servers[String(serverId).toLowerCase()] = String(changeId)
    const orderedServers = Object.fromEntries(
      Object.entries(current.servers).sort(([left], [right]) => left.localeCompare(right)),
    )
    const value = JSON.stringify({
      schemaVersion: 1,
      revision: String(changeId),
      servers: orderedServers,
    })
    descriptor = fs.openSync(temporary, 'wx', 0o600)
    fs.writeFileSync(descriptor, `${value}\n`)
    fs.fsyncSync(descriptor)
    fs.closeSync(descriptor)
    descriptor = null
    fs.renameSync(temporary, target)
    // The marker closes the provider-keyring → app-ledger crash window across daemon relaunch.
    // Persist both bytes and directory entry before reporting that the credential generation moved.
    try {
      const directory = fs.openSync(codexHome, 'r')
      try { fs.fsyncSync(directory) } finally { fs.closeSync(directory) }
    } catch {}
  } finally {
    if (descriptor !== null) try { fs.closeSync(descriptor) } catch {}
    try { fs.unlinkSync(temporary) } catch {}
  }
  return String(changeId)
}

/// A Codex thread captures its MCP tool schema when it is created. Bind the opaque provider session
/// to non-secret configuration identity so a daemon relaunched after OAuth cannot resume a thread
/// whose immutable schema predates that credential. Raw extension bytes can contain Keychain
/// references but never credential values; the OAuth marker is a random change identity.
export function codexMcpThreadSchemaState({ extensionsFile, codexHome } = {}) {
  const snapshot = codexMcpExtensionsSchemaSnapshot(extensionsFile)
  const configuredServers = snapshot.servers.length
  const credentialGeneration = readCodexMcpCredentialGeneration(codexHome)
  return {
    fingerprint: createHash('sha256')
      .update(snapshot.schemaFingerprint)
      .update('\0')
      .update(credentialGeneration)
      .digest('hex'),
    // Legacy sessions have no proof. Keep them resumable when MCP has never been configured, but
    // replace them once when an existing installation first adopts this generation contract.
    requiresProof: configuredServers > 0 || credentialGeneration.length > 0,
  }
}

export function codexThreadSession(sessionId) {
  if (typeof sessionId !== 'string' || !sessionId.startsWith(CODEX_SESSION_PREFIX)) return null
  let encoded = sessionId.slice(CODEX_SESSION_PREFIX.length)
  if (!encoded) return null
  let toolProfile = null
  const profileIndex = encoded.lastIndexOf(CODEX_TOOL_PROFILE_SESSION_PROOF)
  if (profileIndex >= 0) {
    const candidate = encoded.slice(profileIndex + CODEX_TOOL_PROFILE_SESSION_PROOF.length)
    if (/^[a-z][a-z0-9-]{0,63}$/.test(candidate)) {
      toolProfile = candidate
      encoded = encoded.slice(0, profileIndex)
    }
  }
  const proofIndex = encoded.lastIndexOf(CODEX_MCP_SESSION_PROOF)
  if (proofIndex < 0) return { threadId: encoded, mcpFingerprint: null, toolProfile }
  const fingerprint = encoded.slice(proofIndex + CODEX_MCP_SESSION_PROOF.length)
  if (!/^[a-f0-9]{64}$/.test(fingerprint)) {
    return { threadId: encoded, mcpFingerprint: null, toolProfile }
  }
  const threadId = encoded.slice(0, proofIndex)
  return threadId ? { threadId, mcpFingerprint: fingerprint, toolProfile } : null
}

export function codexSessionForThread(threadId, mcpFingerprint, toolProfile = null) {
  if (typeof threadId !== 'string' || !threadId) return null
  const schemaProof = typeof mcpFingerprint === 'string' && /^[a-f0-9]{64}$/.test(mcpFingerprint)
    ? `${CODEX_MCP_SESSION_PROOF}${mcpFingerprint}` : ''
  const profileProof = typeof toolProfile === 'string'
      && /^[a-z][a-z0-9-]{0,63}$/.test(toolProfile)
    ? `${CODEX_TOOL_PROFILE_SESSION_PROOF}${toolProfile}` : ''
  return `${CODEX_SESSION_PREFIX}${threadId}${schemaProof}${profileProof}`
}

/// A legacy session predates closed profiles and is therefore standard. Every non-legacy session
/// names its immutable dynamic-tool profile explicitly so neither a daemon relaunch nor an app-side
/// routing bug can resume a broader thread under a narrower profile (or widen one in reverse).
export function codexThreadSessionHasProfileMismatch(sessionId, toolProfile) {
  const session = codexThreadSession(sessionId)
  if (!session) return false
  const storedProfile = session.toolProfile || 'standard'
  return typeof toolProfile !== 'string' || storedProfile !== toolProfile
}

export function codexThreadSessionNeedsReplacement(sessionId, schemaState) {
  const session = codexThreadSession(sessionId)
  if (!session) return false
  if (session.mcpFingerprint) return session.mcpFingerprint !== schemaState?.fingerprint
  return schemaState?.requiresProof === true
}

function normalizedEnvironment(environment) {
  return environment && typeof environment === 'object' ? environment : {}
}

/// Every variable carried by either process generation must stay excluded from model-run shells
/// until the old process has exited.  Values are deliberately ignored: rotations under the same
/// variable still require a restart, but do not change the exclusion set.
export function codexMcpRetainedExclusions(...environments) {
  return [...new Set(environments.flatMap((environment) =>
    Object.keys(normalizedEnvironment(environment))))].sort()
}

/// Decide how a completed config-file write must be made visible.
export function codexMcpGenerationAction({ hasApp, previousEnv, nextEnv, envChanged }) {
  if (!hasApp) return 'persisted'
  return envChanged(normalizedEnvironment(previousEnv), normalizedEnvironment(nextEnv))
    ? 'restart'
    : 'reload'
}

/// Fence a controlled restart on the operating-system child exit event. CodexAppServer.close()
/// closes the JSON-RPC transport immediately but deliberately returns while SIGTERM/SIGKILL is
/// still being processed, so its return value is not a process-generation boundary.
export function waitForCodexProcessExit(child, { timeoutMs = 15_000 } = {}) {
  if (!child || child.exitCode != null || child.signalCode != null) return Promise.resolve()
  return new Promise((resolve, reject) => {
    let timer = null
    let childError = null
    const cleanup = () => {
      child.removeListener?.('exit', exited)
      child.removeListener?.('error', observedError)
      if (timer) clearTimeout(timer)
    }
    const exited = () => {
      cleanup()
      resolve()
    }
    // An error event is not OS proof that the child is gone. Keep waiting for exit; retain the
    // diagnostic only in case the bounded exit fence itself expires.
    const observedError = (error) => { childError = error }
    child.once?.('exit', exited)
    child.on?.('error', observedError)
    timer = setTimeout(() => {
      cleanup()
      reject(childError instanceof Error
        ? childError
        : new Error('Timed out waiting for the replaced Codex App Server process to exit.'))
    }, timeoutMs)
    timer.unref?.()
  })
}

/**
 * @param {{invalidate?: (reason: string, generation: number) => void}} options
 */
export function createCodexMcpGenerationCoordinator({ invalidate = () => {} } = {}) {
  let requestedGeneration = 0
  let completedGeneration = 0
  let tail = Promise.resolve()
  let pending = null

  function request(reason, apply) {
    if (typeof apply !== 'function') throw new TypeError('Codex MCP generation apply must be a function.')
    const generation = ++requestedGeneration
    // Invalidate synchronously. A prewarm scheduled later in this same run-loop must never claim
    // proof from the generation that this request has already superseded.
    invalidate(String(reason || 'MCP configuration changed'), generation)
    const operation = tail
      .catch(() => {}) // one surfaced failure must not permanently poison later repair attempts
      .then(() => apply({ generation, reason: String(reason || '') }))
    tail = operation
    pending = operation
    const settle = (completed) => {
      if (completed) completedGeneration = Math.max(completedGeneration, generation)
      if (pending === operation) pending = null
    }
    operation.then(() => settle(true), () => settle(false))
    return operation
  }

  async function awaitReady() {
    // A second request can queue while the caller is awaiting the first. Join through the newest
    // observed tail so a thread cannot slip between two back-to-back configuration generations.
    // Keep observing the settled tail too: if the newest apply failed, future threads must fail
    // closed until a later explicit generation repairs it.
    while (true) {
      const operation = tail
      await operation
      if (tail === operation) break
    }
    return completedGeneration
  }

  return {
    request,
    awaitReady,
    get pending() { return pending !== null },
    get requestedGeneration() { return requestedGeneration },
    get completedGeneration() { return completedGeneration },
  }
}
