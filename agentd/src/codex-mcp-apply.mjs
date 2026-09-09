// Apply Mechanician's MCP servers to the Codex lane: config to disk, credentials to the process
// environment, and an honest list of what could not be carried across.
//
// The split matters. Server DEFINITIONS go into $CODEX_HOME/config.toml, which Codex re-reads
// without a restart. Server CREDENTIALS go into the app-server's environment, which is fixed at
// spawn — so adding a secret-backed server is the one change that cannot be applied hot, and the
// caller is told so rather than left believing it worked.

import fs from 'node:fs'
import path from 'node:path'
import { createHash, randomUUID } from 'node:crypto'

import {
  foreignServerNames,
  hasForeignShellEnvironmentPolicy,
  managedCodexExclusions,
  mergeManagedCodexConfig,
  renderManagedCodexConfig,
} from './codex-config-file.mjs'
import { codexSecretExclusions, translateMcpServersForCodex } from './codex-mcp-config.mjs'
import { accountFromMCPSecretReference, readMCPKeychainSecret } from './mcp-secrets.mjs'
import { withCodexMcpConfigLock } from './codex-mcp-config-lock.mjs'
import {
  codexMcpExtensionsSchemaSnapshot,
  readCodexMcpCredentialGeneration,
} from './codex-mcp-generation.mjs'

function readRawServersSnapshot(extensionsFile) {
  return codexMcpExtensionsSchemaSnapshot(extensionsFile)
}

function readExisting(configPath) {
  try { return fs.readFileSync(configPath, 'utf8') } catch { return '' }
}

function sourceFingerprint(schemaFingerprint, credentials, codexHome) {
  return createHash('sha256')
    .update(schemaFingerprint)
    .update('\0')
    .update(JSON.stringify(credentials))
    .update('\0')
    .update(readCodexMcpCredentialGeneration(codexHome))
    .digest('hex')
}

function resolveSourceCredentials(secretEnv, readSecret) {
  return secretEnv
    .map((entry) => {
      let value
      try { value = readSecret(accountFromMCPSecretReference(entry.reference)) }
      catch { value = null }
      return [entry.variable, entry.reference, value]
    })
    .sort(([leftVariable, leftReference], [rightVariable, rightReference]) =>
      leftVariable.localeCompare(rightVariable) || leftReference.localeCompare(rightReference))
}

/**
 * @returns {{
 *   env: Record<string, string>,     // credentials for the app-server process, never the config
 *   unsupported: Array<{name: string, reason: string}>,
 *   servers: string[],               // names actually written
 *   configPath: string,
 * }}
 */
export function applyCodexMcpConfig({
  extensionsFile,
  codexHome,
  readSecret = readMCPKeychainSecret,
  retainedExclusions = [],
  alreadyLocked = false,
  log = () => {},
} = {}) {
  const configPath = path.join(codexHome, 'config.toml')
  fs.mkdirSync(codexHome, { recursive: true })
  let applied = null
  for (let attempt = 0; attempt < 5 && !applied; attempt += 1) {
    const snapshot = readRawServersSnapshot(extensionsFile)
    const { servers, secretEnv, unsupported } = translateMcpServersForCodex(snapshot.servers)
    const sourceCredentials = resolveSourceCredentials(secretEnv, readSecret)
    // Resolve credentials before taking the writer lock, then validate the exact extensions bytes
    // after acquisition and immediately before publish. A slow old-generation writer can never
    // acquire last and overwrite definitions from a newer atomic extensions.json replacement.
    const env = {}
    const usable = new Set(Object.keys(servers))
    for (const entry of secretEnv) {
      if (!usable.has(entry.server)) continue
      try {
        env[entry.variable] = readSecret(accountFromMCPSecretReference(entry.reference))
      } catch {
        delete servers[entry.server]
        usable.delete(entry.server)
        unsupported.push({
          name: entry.server,
          reason: 'Its stored credentials could not be read from the Keychain.',
        })
      }
    }
    for (const key of Object.keys(env)) {
      if (!secretEnv.some((entry) => entry.variable === key && usable.has(entry.server))) {
        delete env[key]
      }
    }

    let stale = false
    const writeGeneration = () => {
      if (readRawServersSnapshot(extensionsFile).rawFingerprint !== snapshot.rawFingerprint) {
        stale = true
        return null
      }
      const existing = readExisting(configPath)
      const foreign = foreignServerNames(existing)
      for (const name of Object.keys(servers)) {
        if (!foreign.has(name)) continue
        delete servers[name]
        usable.delete(name)
        unsupported.push({
          name,
          reason: 'A server with this name is already configured in Codex outside Mechanician.',
        })
      }
      for (const key of Object.keys(env)) {
        if (!secretEnv.some((entry) => entry.variable === key && usable.has(entry.server))) {
          delete env[key]
        }
      }
      const exclusions = [...new Set([
        // Monotonic by design. This writer cannot prove a sibling with N-2 env has exited.
        ...managedCodexExclusions(existing),
        ...codexSecretExclusions(secretEnv.filter((entry) => usable.has(entry.server))),
        ...(Array.isArray(retainedExclusions) ? retainedExclusions : []),
      ])].sort()
      if (exclusions.length && hasForeignShellEnvironmentPolicy(existing)) {
        throw new Error(
          'Codex already defines shell_environment_policy outside Mechanician; '
          + 'credential-backed MCP servers cannot be added safely.',
        )
      }
      const merged = mergeManagedCodexConfig(
        existing,
        renderManagedCodexConfig(servers, { exclusions }),
      )
      if (readRawServersSnapshot(extensionsFile).rawFingerprint !== snapshot.rawFingerprint
          || readExisting(configPath) !== existing) {
        stale = true
        return null
      }
      const result = {
        env, unsupported, servers: Object.keys(servers), exclusions, configPath,
        extensionsFingerprint: snapshot.schemaFingerprint,
        sourceFingerprint: sourceFingerprint(
          snapshot.schemaFingerprint, sourceCredentials, codexHome),
      }
      // Config file watchers treat a rename as a real generation even when the bytes are equal.
      // Preserve the existing inode/mtime on a no-op so per-turn sibling convergence cannot churn
      // Codex's watcher or widen the window in which a Codex-owned write races this managed one.
      if (merged === existing) return result
      const temporary = `${configPath}.mechanician-${process.pid}-${randomUUID()}`
      try {
        fs.writeFileSync(temporary, merged, { mode: 0o600 })
        fs.renameSync(temporary, configPath)
      } finally {
        try { fs.unlinkSync(temporary) } catch {}
      }
      return result
    }
    applied = alreadyLocked
      ? writeGeneration()
      : withCodexMcpConfigLock(codexHome, writeGeneration)
    if (!applied && !stale) throw new Error('Codex MCP configuration could not be applied.')
  }
  if (!applied) {
    throw new Error('Extensions changed repeatedly while Codex MCP configuration was being applied.')
  }
  for (const item of applied.unsupported) {
    log(`[codex] MCP server ${item.name} was not configured: ${item.reason}`)
  }
  return applied
}

/// Whether a change can be applied to a RUNNING app-server. Definitions reload from the file;
/// credentials cannot, because the process environment is fixed at spawn.
export function codexMcpEnvChanged(previous, next) {
  const before = Object.keys(previous || {}).sort()
  const after = Object.keys(next || {}).sort()
  if (before.length !== after.length) return true
  if (before.some((key, index) => key !== after[index])) return true
  return before.some((key) => previous[key] !== next[key])
}

/// Non-secret identity for the configuration/environment generation. Independent agentd processes
/// share extensions.json/CODEX_HOME but not memory, so every Codex turn compares this fingerprint
/// with the process it is about to lease and self-converges if another window changed the file.
export function codexMcpConfigurationFingerprint({
  extensionsFile,
  codexHome,
  readSecret = readMCPKeychainSecret,
} = {}) {
  const snapshot = readRawServersSnapshot(extensionsFile)
  const { secretEnv } = translateMcpServersForCodex(snapshot.servers)
  // Credential values remain transient hash input and are never returned, persisted, or logged.
  return sourceFingerprint(
    snapshot.schemaFingerprint,
    resolveSourceCredentials(secretEnv, readSecret),
    codexHome,
  )
}
