import assert from 'node:assert/strict'
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { test } from 'node:test'

// A turn does not rebuild its extension set: it claims a prewarmed spare carrying the `ext` computed
// when that spare was armed. Authorizing a server changes what the extension set is, and nothing
// invalidated the spare or the prepared-extensions cache — so the next turn ran with the
// pre-authorization snapshot and the agent could not see the new tools. Whether it worked came down
// to whether the spare happened to lapse and re-arm in between, which is why the tools appeared
// "sometimes, if you ask again".
//
// This is a source-level guard rather than a live OAuth run: driving a real authorization needs an
// MCP server that grants tokens. It cannot prove the caches are empty, but it does catch the
// regression that actually happened — an authorize path that reports success without invalidating.
const here = path.dirname(fileURLToPath(import.meta.url))
const source = fs.readFileSync(path.resolve(here, '../src/agentd.mjs'), 'utf8')

const lines = source.split('\n')

function lineNumbersMatching(pattern) {
  return lines
    .map((text, index) => (pattern.test(text) ? index + 1 : 0))
    .filter(Boolean)
}

test('every successful MCP authorization invalidates the cached extension set before success', () => {
  const successes = lineNumbersMatching(/type:\s*'mcp_authorize_ok'/)
  assert.ok(successes.length > 0, 'expected at least one authorize-success emission')

  for (const line of successes) {
    // `emit` makes success observable to the app. The app can immediately enable the composer and
    // start a turn in another process, so invalidating after this line preserves the exact race the
    // boundary is meant to close even when JavaScript itself does not yield between statements.
    const window = lines.slice(Math.max(0, line - 28), line).join('\n')
    assert.match(
      window,
      /invalidateExtensionSnapshots\(/,
      `mcp_authorize_ok at line ${line} becomes observable before invalidating the extension `
        + 'snapshots, so an immediate next turn can claim a prewarmed spare built before the '
        + 'credential existed and the agent will not see the new tools',
    )
  }
})

test('both Claude OAuth paths close the durable attempt only after cache convergence', () => {
  const authorizeStart = source.indexOf('async function handleMcpAuthorize')
  const configuredStart = source.indexOf('if (oauthServer) {', authorizeStart)
  const configuredEnd = source.indexOf("if (mode !== 'sdk'", configuredStart)
  const providerEnd = source.indexOf('// Completion signal for a claude.ai connector', configuredEnd)
  assert.ok(authorizeStart >= 0 && configuredStart > authorizeStart
    && configuredEnd > configuredStart && providerEnd > configuredEnd)

  for (const [label, flow] of [
    ['configured server', source.slice(configuredStart, configuredEnd)],
    ['provider connector', source.slice(configuredEnd, providerEnd)],
  ]) {
    const invalidation = flow.indexOf('invalidateExtensionSnapshots(')
    const claim = flow.indexOf('rememberMcpReadinessClaim(', invalidation)
    const activating = flow.indexOf("activation: 'activating'", claim)
    const ready = flow.indexOf("activation: 'ready'", activating)
    const terminal = flow.indexOf("type: 'mcp_authorize_ok'", ready)
    assert.ok(invalidation >= 0 && claim > invalidation && activating > claim
      && ready > activating && terminal > ready,
    `${label} must invalidate stale provider snapshots, install the exact next-turn claim, `
      + 'then close the durable attempt before its request terminal becomes observable')
    assert.match(flow.slice(terminal), /activation: 'failed'/,
      `${label} must close a mutation-ambiguous authorization failure`)
  }
})

test('clearing an MCP credential invalidates the same snapshots', () => {
  const cleared = lineNumbersMatching(/type:\s*'mcp_clear_auth_ok'/)
  assert.ok(cleared.length > 0, 'expected a clear-auth success emission')

  for (const line of cleared) {
    const window = lines.slice(Math.max(0, line - 16), line + 1).join('\n')
    assert.match(
      window,
      /invalidateExtensionSnapshots\(/,
      `mcp_clear_auth_ok at line ${line} removes a credential without invalidating the snapshots `
        + 'that were computed while it existed',
    )
  }
})

test('the invalidation drops the warm spare and the prepared extensions', () => {
  const helper = source.slice(
    source.indexOf('function invalidateExtensionSnapshots'),
    source.indexOf('function handleMcpReload'),
  )
  assert.ok(helper.length > 0, 'expected an invalidateExtensionSnapshots helper')
  assert.match(helper, /claudeWarmQueries\.clear\(/, 'the prewarmed spare carries the stale ext')
  assert.match(helper, /preparedUserExtensions\.invalidate\(/)
  assert.match(helper, /mcpAvailability\.clearCache\(/)
  // The caller has just recorded an accurate status for the server it acted on; discarding it would
  // replace a known answer with an unknown one.
  assert.doesNotMatch(helper, /latestMCPStatusByName\.clear\(/)
})

test('configured Claude credential persistence is observable without its cancelled request owner', () => {
  const configuredStart = source.indexOf('if (oauthServer) {')
  const configuredEnd = source.indexOf("if (mode !== 'sdk'", configuredStart)
  assert.notEqual(configuredStart, -1)
  assert.notEqual(configuredEnd, -1)
  const configuredAuthorize = source.slice(configuredStart, configuredEnd)

  const mutation = configuredAuthorize.indexOf("type: 'mcp_credentials_changed'")
  const requestTerminal = configuredAuthorize.indexOf("type: 'mcp_authorize_ok'")
  assert.ok(mutation >= 0,
    'the Keychain mutation must be emitted as a lane fact even if Cancel already retired the request')
  assert.ok(requestTerminal < 0 || mutation < requestTerminal,
    'session invalidation must become observable before request-owned success')
  assert.match(configuredAuthorize, /changeId/,
    'the unowned mutation needs a stable id so app windows can deduplicate it')
})

test('successful Codex clear retires positive readiness instead of creating a no-tools gate', () => {
  const clearStart = source.indexOf('async function handleMcpClearAuth')
  const claudeStart = source.indexOf('const loaded = loadUserExtensions()', clearStart)
  assert.notEqual(clearStart, -1)
  assert.notEqual(claudeStart, -1)
  const codexClear = source.slice(clearStart, claudeStart)

  assert.match(
    codexClear,
    /recentlyAuthorizedMcpClaims\.delete|retireMcpReadinessClaim/,
    'clearing auth must remove an older positive post-auth claim before the next fresh turn')
  assert.doesNotMatch(
    codexClear,
    /rememberMcpReadinessClaim/,
    'a server that now needs auth cannot satisfy positive agent-tool readiness')
})
