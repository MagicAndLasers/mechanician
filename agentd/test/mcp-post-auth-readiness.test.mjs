import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { test } from 'node:test'

import {
  mcpReadinessClaims,
  mcpReadinessServerNames,
  mcpTurnReadinessDecision,
  waitForMcpTurnReadiness,
} from '../src/mcp-turn-readiness.mjs'

const agentdSource = readFileSync(new URL('../src/agentd.mjs', import.meta.url), 'utf8')
const accountInstanceId = 'a1faed81-8eba-4242-97fa-b3a5d9212585'
const claudeRouteIdentity = 'anthropic:subscription:builtin'

test('the first fresh turn gates a just-authorized deferred server', () => {
  const servers = {
    deferred: { type: 'http', url: 'https://mcp.example/deferred' },
    eager: { type: 'stdio', command: 'fixture', alwaysLoad: true },
    unrelated: { type: 'http', url: 'https://mcp.example/unrelated' },
  }

  assert.deepEqual(
    mcpReadinessServerNames(servers, ['deferred']),
    ['deferred', 'eager'],
    'post-auth readiness is a one-generation exception to normal deferred startup')
  assert.deepEqual(
    mcpReadinessServerNames(servers, []),
    ['eager'],
    'later turns return to the ordinary eager-only readiness budget')
})

test('post-auth readiness is scoped to the provider lane generation that completed auth', () => {
  const claudeServers = {
    VICE: { type: 'http', url: 'https://mcp.example/vice' },
  }
  const otherLaneServers = {
    GitHub: { type: 'http', url: 'https://mcp.example/github' },
  }

  assert.deepEqual(mcpReadinessServerNames(claudeServers, ['VICE']), ['VICE'])
  assert.deepEqual(
    mcpReadinessServerNames(otherLaneServers, []),
    [],
    'the app must hand each daemon only claims scoped to that exact provider route')
})

test('post-auth readiness fails closed for an absent claim and ignores malformed duplicates', () => {
  const servers = {
    VICE: { type: 'http', url: 'https://mcp.example/vice' },
    eager: { type: 'stdio', command: 'fixture', alwaysLoad: true },
  }

  assert.deepEqual(
    mcpReadinessServerNames(
      servers,
      ['VICE', 'VICE', 'removed-server', '', null, 'x'.repeat(501)],
    ),
    ['VICE', 'removed-server', 'eager'],
    'an exact pending generation missing from the prepared mount must remain visible so the turn '
      + 'fails closed instead of silently minting a tool-less session')
})

test('readiness claims require exact bounded server and generation identities', () => {
  assert.deepEqual(mcpReadinessClaims([
    {
      name: 'VICE', changeId: 'generation-a', source: 'configured',
      serverId: '7f661a72-4885-42ad-bce1-242b6741d88a',
      accountInstanceId, routeIdentity: claudeRouteIdentity,
    },
    {
      name: 'Connector', changeId: 'generation-b', source: 'providerConnector',
      accountInstanceId, routeIdentity: claudeRouteIdentity,
    },
    { name: 'missing-generation' },
    { changeId: 'missing-name' },
    { name: '', changeId: 'empty-name' },
    { name: 'oversized', changeId: 'x'.repeat(501) },
    { name: 'bad-source', changeId: 'generation-c', source: 'unknown' },
    {
      name: 'configured-no-id', changeId: 'generation-d', source: 'configured',
      accountInstanceId, routeIdentity: claudeRouteIdentity,
    },
    {
      name: 'configured-bad-id', changeId: 'generation-e', source: 'configured',
      serverId: 'not-a-uuid', accountInstanceId, routeIdentity: claudeRouteIdentity,
    },
    {
      name: 'missing-account', changeId: 'generation-f', source: 'providerConnector',
      routeIdentity: claudeRouteIdentity,
    },
    {
      name: 'missing-route', changeId: 'generation-g', source: 'providerConnector',
      accountInstanceId,
    },
  ]), [
    {
      name: 'VICE', changeId: 'generation-a', source: 'configured',
      serverId: '7f661a72-4885-42ad-bce1-242b6741d88a',
      accountInstanceId, routeIdentity: claudeRouteIdentity,
    },
    {
      name: 'Connector', changeId: 'generation-b', source: 'providerConnector',
      accountInstanceId, routeIdentity: claudeRouteIdentity,
    },
  ], 'claims need exact generation/provenance, and configured claims need stable server identity')
})

test('the same name cannot ambiguously identify configured and provider-owned auth', () => {
  assert.throws(() => mcpReadinessClaims([
    {
      name: 'VICE', changeId: 'configured-generation', source: 'configured',
      serverId: '7f661a72-4885-42ad-bce1-242b6741d88a',
      accountInstanceId, routeIdentity: claudeRouteIdentity,
    },
    {
      name: 'VICE', changeId: 'connector-generation', source: 'providerConnector',
      accountInstanceId, routeIdentity: claudeRouteIdentity,
    },
  ]), /Conflicting MCP readiness sources/)
})

test('stable configured identity follows rename while same-name replacement is ambiguous', () => {
  const serverId = '7f661a72-4885-42ad-bce1-242b6741d88a'
  assert.deepEqual(mcpReadinessClaims([
    {
      name: 'VICE', changeId: 'generation-a', source: 'configured', serverId,
      accountInstanceId, routeIdentity: claudeRouteIdentity,
    },
    {
      name: 'VICE Renamed', changeId: 'generation-a', source: 'configured', serverId,
      accountInstanceId, routeIdentity: claudeRouteIdentity,
    },
  ]), [{
    name: 'VICE Renamed', changeId: 'generation-a', source: 'configured', serverId,
    accountInstanceId, routeIdentity: claudeRouteIdentity,
  }])

  assert.throws(() => mcpReadinessClaims([
    {
      name: 'VICE', changeId: 'old-row', source: 'configured', serverId,
      accountInstanceId, routeIdentity: claudeRouteIdentity,
    },
    {
      name: 'VICE', changeId: 'replacement-row', source: 'configured',
      serverId: 'e65b4b19-4cf3-4f45-b65d-4536bf6bf023',
      accountInstanceId, routeIdentity: claudeRouteIdentity,
    },
  ]), /Conflicting MCP readiness sources/)
})

test('one stable server identity cannot carry two credential generations in one request', () => {
  const serverId = '7f661a72-4885-42ad-bce1-242b6741d88a'
  assert.throws(() => mcpReadinessClaims([
    {
      name: 'VICE', changeId: 'generation-a', source: 'configured', serverId,
      accountInstanceId, routeIdentity: claudeRouteIdentity,
    },
    {
      name: 'VICE Renamed', changeId: 'generation-b', source: 'configured', serverId,
      accountInstanceId, routeIdentity: claudeRouteIdentity,
    },
  ]), /Conflicting MCP readiness generations/,
  'array ordering must not decide which generation is allowed to mint the fresh provider session')
})

test('configured readiness preserves the stable server identity on the wire', () => {
  assert.deepEqual(mcpReadinessClaims([{
    name: 'VICE', changeId: 'generation-a', source: 'configured',
    serverId: '7f661a72-4885-42ad-bce1-242b6741d88a',
    accountInstanceId, routeIdentity: claudeRouteIdentity,
  }]), [{
    name: 'VICE', changeId: 'generation-a', source: 'configured',
    serverId: '7f661a72-4885-42ad-bce1-242b6741d88a',
    accountInstanceId, routeIdentity: claudeRouteIdentity,
  }])
})

test('a just-authorized server reaches real tool inventory before prompt delivery', async () => {
  const snapshots = [
    [{ name: 'VICE', status: 'authenticated' }],
    [{ name: 'VICE', status: 'pending' }],
    [{ name: 'VICE', status: 'connected', tools: [{ name: 'search' }, { name: 'fetch' }] }],
  ]
  const progress = []

  const result = await waitForMcpTurnReadiness(
    { mcpServerStatus: async () => snapshots.shift() },
    ['VICE'],
    {
      authorizationStates: { VICE: 'authenticated' },
      timeoutMs: 100,
      pollIntervalMs: 1,
      controlTimeoutMs: 20,
      onSnapshot: (snapshot) => progress.push(snapshot),
    },
  )

  assert.deepEqual(result, [{
    name: 'VICE', status: 'connected', tools: 2, error: null,
  }])
  assert.deepEqual(progress.map((snapshot) => snapshot[0].status), [
    'authenticated', 'pending', 'connected',
  ])
})

test('post-auth readiness returns a truthful zero-tool inventory', async () => {
  const result = await waitForMcpTurnReadiness(
    { mcpServerStatus: async () => [{ name: 'VICE', status: 'connected', tools: [] }] },
    ['VICE'],
    {
      authorizationStates: { VICE: 'authenticated' },
      timeoutMs: 100,
      pollIntervalMs: 1,
      controlTimeoutMs: 20,
    },
  )

  assert.deepEqual(result, [{
    name: 'VICE', status: 'connected', tools: 0, error: null,
  }])
})

test('a promoted server that times out unresolved cannot receive the prompt', () => {
  for (const status of ['authenticated', 'pending', 'checking', 'unverified']) {
    assert.deepEqual(
      mcpTurnReadinessDecision(
        [{ name: 'VICE', status, tools: null }],
        { promotedNames: ['VICE'] },
      ),
      { unresolvedPromotedNames: ['VICE'], mayDeliverPrompt: false },
      `${status} is not proof that the fresh provider session mounted the server`)
  }

  assert.deepEqual(
    mcpTurnReadinessDecision([], { promotedNames: ['VICE'] }),
    { unresolvedPromotedNames: ['VICE'], mayDeliverPrompt: false },
    'a missing status row is unresolved, not permission to mint a resumable tool-less session')
})

test('promoted success requires connected plus a positive agent-visible tool inventory', () => {
  assert.deepEqual(
    mcpTurnReadinessDecision(
      [{ name: 'VICE', status: 'connected', tools: 2 }],
      { promotedNames: ['VICE'] },
    ),
    { unresolvedPromotedNames: [], mayDeliverPrompt: true })
})

test('zero tools, missing inventory, and terminal failures cannot mint the promoted session', () => {
  for (const [status, tools] of [
    ['connected', 0],
    ['connected', null],
    ['needs-auth', null],
    ['failed', null],
    ['disabled', null],
  ]) {
    assert.deepEqual(
      mcpTurnReadinessDecision(
        [{ name: 'VICE', status, tools }],
        { promotedNames: ['VICE'] },
      ),
      { unresolvedPromotedNames: ['VICE'], mayDeliverPrompt: false },
      `${status} with inventory ${String(tools)} is not proof that the new tools mounted`)
  }
})

test('ordinary eager readiness remains bounded best effort', () => {
  assert.deepEqual(
    mcpTurnReadinessDecision(
      [{ name: 'slow-eager', status: 'pending', tools: null }],
      { promotedNames: [] },
    ),
    { unresolvedPromotedNames: [], mayDeliverPrompt: true },
    'a normal eager server timing out must not turn the existing latency bound into a hard failure')
})

test('request-carried promotion survives another daemon and an absent prepared mount fails closed', () => {
  const requestClaims = mcpReadinessClaims([{
    name: 'VICE', changeId: 'generation-b', source: 'configured',
    serverId: '7f661a72-4885-42ad-bce1-242b6741d88a',
    accountInstanceId, routeIdentity: claudeRouteIdentity,
  }])
  const requestNames = requestClaims.map((claim) => claim.name)
  const secondDaemonLocalClaims = []
  const configuredAfterSecurePreparation = {}

  assert.deepEqual(
    mcpReadinessServerNames(
      configuredAfterSecurePreparation,
      [...secondDaemonLocalClaims.map((claim) => claim.name), ...requestNames],
    ),
    ['VICE'],
    'a durable request handoff must not be filtered away when credential preparation omitted the '
      + 'server; absence is an unresolved failure, not a tool-less success')
  assert.deepEqual(
    mcpTurnReadinessDecision([], { promotedNames: requestNames }),
    { unresolvedPromotedNames: ['VICE'], mayDeliverPrompt: false })
})

test('the promoted gate is resolved before prompt delivery and stays pending on failure', () => {
  const start = agentdSource.indexOf('const promotedClaims =')
  const end = agentdSource.indexOf('// toolUseId -> MCP server name', start)
  assert.notEqual(start, -1)
  assert.notEqual(end, -1)
  const gate = agentdSource.slice(start, end)

  const decision = gate.indexOf('mcpTurnReadinessDecision(statuses')
  const refusal = gate.indexOf('if (!readiness.mayDeliverPrompt)')
  const delivery = gate.lastIndexOf('deliverPrompt()')
  assert.ok(decision >= 0 && refusal > decision && delivery > refusal,
    'the promoted decision must run before the only successful prompt delivery')
  assert.match(gate, /if \(!promotedServerNames\.length\) deliverPrompt\(\)/,
    'only ordinary eager readiness errors retain best-effort prompt delivery')
  assert.doesNotMatch(
    gate.slice(refusal),
    /recentlyAuthorizedMcpServers\.delete/,
    'timeout/error must retain the promotion so a later fresh query gates the same server again')

  const awaitBoundary = gate.indexOf('await startPrompt')
  assert.ok(awaitBoundary > delivery,
    'the daemon must await the gate before consuming provider frames that can contain a session id')
  assert.match(gate, /emit\(\{ type: 'session_invalidated', id \}\)/,
    'a failed promoted gate must explicitly retire any provider session created during startup')

  const proof = gate.indexOf("type: 'mcp_readiness_proof'")
  assert.ok(proof > refusal && proof < delivery,
    'the exact generation proof must be emitted only after readiness succeeds and before prompt delivery')
  const exactGenerationCheck = gate.lastIndexOf(
    'requireCurrentMcpReadinessClaim(claim)', proof)
  assert.ok(exactGenerationCheck > refusal && exactGenerationCheck < proof,
    'a newer auth generation that lands during the async provider poll must abort the old query')
  assert.match(gate.slice(proof, delivery), /changeId:\s*claim\.changeId/)
  assert.match(gate.slice(proof, delivery), /tools:\s*status\.tools/)
})

test('a request-carried old generation cannot overwrite a newer daemon-local claim', () => {
  const start = agentdSource.indexOf('function pendingMcpReadinessClaims(ctx)')
  const end = agentdSource.indexOf('function requireCurrentMcpReadinessClaim', start)
  assert.notEqual(start, -1)
  assert.notEqual(end, -1)
  const merge = agentdSource.slice(start, end)

  assert.match(merge, /if \(local && \(local\.changeId !== claim\.changeId/,
    'the daemon must identify a request generation superseded by its own later credential event')
  assert.match(merge, /throw new Error\(`MCP credential generation changed/,
    'the stale request must fail closed instead of regressing the local map from B back to A')
  assert.match(
    merge,
    /if \(!local \|\| local\.name !== claim\.name\) recentlyAuthorizedMcpClaims\.set\(identity, claim\)/,
    'only an absent local observation or a same-generation stable-id rename may adopt the '
      + 'durable request claim')
})

test('request-carried promotion cannot resume an opaque pre-auth provider session', () => {
  const sendStart = agentdSource.indexOf("case 'send':")
  const sendEnd = agentdSource.indexOf("case 'steer':", sendStart)
  assert.notEqual(sendStart, -1)
  assert.notEqual(sendEnd, -1)
  const setup = agentdSource.slice(sendStart, sendEnd)

  assert.match(
    setup,
    /mcpReadinessClaims/,
    'the daemon must inspect the request-carried promotion before creating the query')
  assert.match(
    setup,
    /sessionId:\s*readinessClaims\.length\s*\?\s*null\s*:\s*requestedSessionId/,
    'nonempty pending readiness must independently null or reject an old app-supplied resume id')
})

test('a sibling daemon invalidates its own pre-auth snapshots before claiming the promoted query', () => {
  const streamStart = agentdSource.indexOf('async function streamOnce(')
  const warmClaim = agentdSource.indexOf('claudeWarmQueries.claim(', streamStart)
  assert.notEqual(streamStart, -1)
  assert.notEqual(warmClaim, -1)
  const setup = agentdSource.slice(streamStart, warmClaim)

  const requestClaim = setup.indexOf('mcpReadiness')
  const invalidation = setup.indexOf('invalidateExtensionSnapshots(')
  assert.ok(requestClaim >= 0 && invalidation > requestClaim,
    'a claim authored by another daemon/window must discard this daemon\'s pre-auth warm query, '
      + 'prepared extension snapshot, and availability result before it can be reused')
})

test('Codex revalidates the exact generation after its async tool poll and before thread start', () => {
  const proofStart = agentdSource.indexOf('async function proveCodexMcpTurnReadiness(ctx)')
  const proofEnd = agentdSource.indexOf('/// Run a plugin operation', proofStart)
  assert.notEqual(proofStart, -1)
  assert.notEqual(proofEnd, -1)
  const proof = agentdSource.slice(proofStart, proofEnd)
  const activation = proof.indexOf('await waitForCodexMcpActivation(claim.name')
  const exactGeneration = proof.indexOf('requireCurrentMcpReadinessClaim(claim)', activation)
  const durableGeneration = proof.indexOf(
    'const currentGeneration = readCodexMcpCredentialGeneration(', exactGeneration)
  const emittedProof = proof.indexOf("type: 'mcp_readiness_proof'", durableGeneration)
  assert.ok(activation >= 0 && exactGeneration > activation
      && durableGeneration > exactGeneration && emittedProof > durableGeneration,
    'generation B arriving while generation A polls must abort A before it can publish proof')

  const runStart = agentdSource.indexOf('async function runCodex(')
  const runEnd = agentdSource.indexOf('async function withMcpServersQuery', runStart)
  const run = agentdSource.slice(runStart, runEnd)
  const gate = run.indexOf('await proveCodexMcpTurnReadiness(ctx)')
  const threadStart = run.indexOf("codexApp.request('thread/start'", gate)
  assert.ok(gate >= 0 && threadStart > gate,
    'Codex must complete exact-generation proof before a resumable thread can be minted')
})

test('account identity rotation retires every provider-owned authorization cache', () => {
  const retireStart = agentdSource.indexOf('function retireMcpAuthorizationStateForAccountReload()')
  const retireEnd = agentdSource.indexOf('// Guard: only one provider-owned connector probe', retireStart)
  assert.notEqual(retireStart, -1)
  assert.notEqual(retireEnd, -1)
  const retire = agentdSource.slice(retireStart, retireEnd)

  assert.match(retire, /for \(const capture of mcpAuthCaptures\.values\(\)\)/)
  assert.match(retire, /capture\?\.cancel\?\.\(\)/)
  assert.match(retire, /mcpAuthCaptures\.clear\(\)/)
  assert.match(retire, /mcpAuthAttempts\.clear\(\)/)
  assert.match(retire, /for \(const waiter of codexOAuthWaiters\.values\(\)\)/)
  assert.match(retire, /clearTimeout\(waiter\.timer\)/)
  assert.match(retire, /codexOAuthWaiters\.clear\(\)/)
  assert.match(retire, /for \(const tombstone of codexCancelledOAuthAttempts\.values\(\)\)/)
  assert.match(retire, /clearTimeout\(tombstone\.timer\)/)
  assert.match(retire, /codexCancelledOAuthAttempts\.clear\(\)/)
  assert.match(retire, /recentlyAuthorizedMcpClaims\.clear\(\)/)

  const reloadStart = agentdSource.indexOf("case 'account_reload':")
  const reloadEnd = agentdSource.indexOf("case 'logout':", reloadStart)
  const reload = agentdSource.slice(reloadStart, reloadEnd)
  const providerRefresh = reload.indexOf('reloadSubscriptionAccount({ publishReady: false })')
  const identityCommit = reload.indexOf('mcpAccountInstanceId = requestedAccountInstanceId')
  const exactSuccessCommit = reload.indexOf('commitAccountReload?.()', providerRefresh)
  const readyPublication = reload.indexOf('emitCodexReady()', exactSuccessCommit)
  const requestTerminal = reload.indexOf("type: 'account_reload_ok'", readyPublication)
  assert.ok(identityCommit >= 0 && providerRefresh >= 0
      && exactSuccessCommit > providerRefresh && readyPublication > exactSuccessCommit
      && requestTerminal > readyPublication,
  'only the exact successful reload may rotate identity before ready and its request terminal')
  assert.doesNotMatch(agentdSource, /pendingAccountReloadReadyCommit/,
    'an unrelated provider ready must never commit a pending account identity')
  assert.match(reload, /The account reload identity is invalid/,
    'malformed account identities must fail before provider credential reload')
})
