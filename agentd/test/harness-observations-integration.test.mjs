import assert from 'node:assert/strict'
import fs from 'node:fs'
import test from 'node:test'

const source = fs.readFileSync(new URL('../src/agentd.mjs', import.meta.url), 'utf8')

function sourceBetween(start, end) {
  const startIndex = source.indexOf(start)
  const endIndex = source.indexOf(end, startIndex + start.length)
  assert.notEqual(startIndex, -1, `missing source boundary: ${start}`)
  assert.notEqual(endIndex, -1, `missing source boundary: ${end}`)
  return source.slice(startIndex, endIndex)
}

test('OTLP metrics are enabled only on primary Claude and Codex provider process construction', () => {
  const prepareClaude = sourceBetween(
    'async function prepareClaudeQuery(',
    'function scheduleClaudePrewarm(',
  )
  assert.match(prepareClaude, /await ensureHarnessMetricsReceiver\(\)/)
  assert.match(prepareClaude, /claudeSDKProcessOptions\(\{ metricsReceiver \}\)/)

  const primaryCodex = sourceBetween(
    'async function startCodexProviderOnce()',
    'function codexTurnIdentity(',
  )
  assert.match(primaryCodex, /await ensureHarnessMetricsReceiver\(\)/)
  assert.match(primaryCodex, /codexOtelMetricsArguments\(metricsReceiver\)/)
  assert.match(primaryCodex, /codexOtelMetricsEnvironment\(metricsReceiver\)/)

  const pluginRental = sourceBetween(
    'async function withCodexPluginServer(',
    'async function handleConfiguredMcpStatus(',
  )
  assert.doesNotMatch(pluginRental, /OtelMetrics|ensureHarnessMetricsReceiver/)
})

test('turn capture emits every bounded harness observation family', () => {
  const requiredCalls = [
    'claudeContextObservation(',
    'claudeResultObservation(',
    'codexRetryObservation(',
    'codexRetryRecoveredObservation(',
    'codexToolObservation(',
    'codexModelObservation(',
    'harnessCompactionObservation(',
    'harnessPhaseObservation(',
  ]
  for (const call of requiredCalls) {
    assert.ok(source.includes(call), `not wired: ${call}`)
  }
  assert.match(source, /beginHarnessTurn\(ctx, 'claude'\)/)
  assert.match(source, /beginHarnessTurn\(ctx, 'codex'/)
  for (const phase of [
    'provider_ready', 'thread_ready', 'request_accepted', 'first_output', 'terminal',
  ]) assert.match(source, new RegExp(`emitHarnessPhase\\(ctx, '${phase}'`))
  assert.match(source, /noteCodexHarnessItemStarted\([^)]*params\.startedAtMs/s)
  assert.match(source, /takeCodexHarnessItemTiming\([^)]*params\.completedAtMs/s)
})

test('usage observations are provenance-tagged and Claude stable message ids are deduped', () => {
  assert.match(source, /claimClaudeAssistantUsageSample\(ctx\.claudeAssistantUsageMessageIDs, message\)/)
  const usageEmits = [...source.matchAll(/emit\(\{[\s\S]{0,260}?type: 'usage',[\s\S]{0,600}?\}\)/g)]
  assert.equal(usageEmits.length, 3)
  for (const match of usageEmits) {
    assert.match(match[0], /provenance: 'provider_report'/)
    assert.match(match[0], /scope: 'request'/)
    assert.match(match[0], /aggregation: '(delta|final)'/)
  }
  const claudeStream = sourceBetween('async function streamOnce(', 'function emitWorkflowUpdate(')
  assert.match(claudeStream, /const providerQuerySequence = ctx\.claudeProviderQuerySequence/)
  assert.match(claudeStream, /type: 'usage',[\s\S]{0,180}?providerQuerySequence/)
  assert.match(claudeStream, /claudeResultObservation\(\{ id, message, providerQuerySequence \}\)/)
  assert.match(
    claudeStream,
    /emitWorkflowUpdate\(\s*correlation\.ownerTurnId \?\? id,\s*message,\s*correlation,\s*providerQuerySequence,?\s*\)/,
  )
  const workflowEmitter = sourceBetween('function emitWorkflowUpdate(', '// --- Real Claude Agent SDK path')
  assert.match(workflowEmitter, /providerQuerySequence: querySequence/)
})

test('Codex account observations consume full reads and sparse updates without turn routing', () => {
  const refresh = sourceBetween(
    'async function refreshCodexHarnessAccountUsage(',
    'async function refreshCodexAccount(',
  )
  assert.match(refresh, /account\/rateLimits\/read/)
  assert.match(refresh, /account\/usage\/read/)
  assert.match(source, /codexRateLimitsObservation\(codexRateLimitState/)
  assert.match(refresh, /codexAccountTokenUsageObservation/)

  const notifications = sourceBetween(
    'async function handleCodexNotification(',
    '/// Ask the person, and answer the server',
  )
  assert.match(notifications, /method === 'account\/rateLimits\/updated'/)
  assert.match(notifications, /updateCodexRateLimitState\(codexRateLimitState, params\)/)
})
