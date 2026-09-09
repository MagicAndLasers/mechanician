import assert from 'node:assert/strict'
import { spawn } from 'node:child_process'
import fs from 'node:fs'
import http from 'node:http'
import os from 'node:os'
import path from 'node:path'
import { test } from 'node:test'
import { fileURLToPath } from 'node:url'

import {
  claudeResultContextUsage,
  MODEL_CATALOG_LIMITS,
  collectCodexCatalog,
  createKeyedSerialExecutor,
  fetchOpenAIModelCatalog,
  normalizeClaudeCatalog,
  normalizeOpenAICatalog,
  validatedCatalogCwd,
  validatedCatalogScope,
} from '../src/model-catalog.mjs'

const here = path.dirname(fileURLToPath(import.meta.url))
const agentd = path.resolve(here, '../src/agentd.mjs')

async function waitFor(predicate, description, timeout = 5000) {
  const deadline = Date.now() + timeout
  while (Date.now() < deadline) {
    const value = predicate()
    if (value) return value
    await new Promise((resolve) => setTimeout(resolve, 10))
  }
  assert.fail(`timed out waiting for ${description}`)
}

function startAgentd(t, { provider, key = '', baseURL = '', disabled = false }) {
  const config = fs.mkdtempSync(path.join(os.tmpdir(), 'mechanician-model-catalog-'))
  const child = spawn(process.execPath, [agentd], {
    env: {
      ...process.env,
      MECHANICIAN_PROVIDER: provider,
      MECHANICIAN_AUTH: 'apikey',
      MECHANICIAN_CONFIG_DIR: config,
      MECHANICIAN_CWD: config,
      MECHANICIAN_ACCOUNT_DISABLED: disabled ? '1' : '0',
      OPENAI_API_KEY: key,
      ANTHROPIC_API_KEY: '',
      CLAUDE_CODE_OAUTH_TOKEN: '',
      ...(baseURL ? { OPENAI_BASE_URL: baseURL } : {}),
    },
    stdio: ['pipe', 'pipe', 'pipe'],
  })
  const events = []
  const errors = []
  let buffered = ''
  child.stdout.setEncoding('utf8')
  child.stdout.on('data', (chunk) => {
    buffered += chunk
    const lines = buffered.split('\n')
    buffered = lines.pop() ?? ''
    for (const line of lines) if (line) events.push(JSON.parse(line))
  })
  child.stderr.setEncoding('utf8')
  child.stderr.on('data', (chunk) => errors.push(chunk))
  t.after(() => {
    if (child.exitCode == null) child.kill()
    fs.rmSync(config, { recursive: true, force: true })
  })
  return { child, events, errors, config }
}

function jsonResponse(value, { status = 200, contentLength = null } = {}) {
  const bytes = new TextEncoder().encode(JSON.stringify(value))
  return {
    ok: status >= 200 && status < 300,
    status,
    headers: { get: (name) => name.toLowerCase() === 'content-length' ? contentLength : null },
    arrayBuffer: async () => bytes.buffer,
  }
}

test('Claude catalog preserves provider metadata, normalizes efforts, and bounds untrusted text', () => {
  const longDescription = `Useful\u0000 model ${'x'.repeat(MODEL_CATALOG_LIMITS.descriptionCharacters + 50)}`
  const { models, truncated } = normalizeClaudeCatalog([
    {
      value: 'sonnet', resolvedModel: 'claude-sonnet-5', displayName: ' Sonnet ',
      description: longDescription,
      supportsEffort: true,
      // `extreme` stands for a level shipped after this build: carried, not dropped. `not a level`
      // is malformed rather than merely unfamiliar, so it is still refused.
      supportedEffortLevels: ['high', 'low', 'none', 'HIGH', 'extreme', 'not a level'],
      supportsAdaptiveThinking: true,
      supportsFastMode: true,
      supportsAutoMode: false,
    },
    { value: 'sonnet', displayName: 'Duplicate must be ignored' },
    { value: 'invalid id', displayName: 'Whitespace IDs are rejected' },
  ])

  assert.equal(truncated, false)
  // Known levels in ladder order, then anything unfamiliar the provider reported. This asserted
  // ['none','low','high'] while the fixture also reported an unrecognized level, which pinned the
  // defect: a tier a provider ships after this build was dropped here, before the app could see it.
  assert.deepEqual(models[0].efforts, ['none', 'low', 'high', 'extreme'])
  assert.deepEqual(models[0].capabilities, ['effort', 'adaptive_thinking', 'fast_mode'])
  assert.equal(models[0].resolvedModelID, 'claude-sonnet-5')
  assert.equal(models[0].label, 'Sonnet 5')
  assert.equal(models[0].description.includes('\u0000'), false)
  assert.equal(models[0].description.length, MODEL_CATALOG_LIMITS.descriptionCharacters)
  assert.equal(models.length, 1)
})

test('Claude catalog carries unfamiliar effort levels but cannot be flooded with them', () => {
  // Opening the vocabulary means the bound is now shape and count rather than membership. A broken
  // or hostile catalog must not be able to turn the effort menu into a wall of rows.
  const { models } = normalizeClaudeCatalog([{
    value: 'sonnet',
    resolvedModel: 'claude-sonnet-5',
    displayName: 'Sonnet',
    supportsEffort: true,
    supportedEffortLevels: ['medium', ...Array.from({ length: 200 }, (_, i) => `level${i}`)],
  }])

  assert.equal(models[0].efforts.length, 16)
  assert.equal(models[0].efforts[0], 'medium', 'a level we can place still leads')
  assert.ok(models[0].efforts.slice(1).every((name) => name.startsWith('level')))
})

test('Claude catalog makes bare family aliases version-explicit', () => {
  const { models } = normalizeClaudeCatalog([
    { value: 'sonnet', resolvedModel: 'claude-sonnet-5', displayName: 'Sonnet' },
    { value: 'fable', resolvedModel: 'claude-fable-5-1', displayName: 'Fable' },
    {
      value: 'opus-5',
      resolvedModel: 'claude-opus-5[1m]',
      displayName: 'Opus (1M context)',
    },
    { value: 'opus', resolvedModel: 'claude-opus-4-8[1m]', displayName: 'Opus' },
    { value: 'haiku', resolvedModel: 'claude-haiku-4-5-20251001', displayName: 'Haiku' },
    {
      value: 'default',
      resolvedModel: 'claude-opus-4-8[1m]',
      displayName: 'Default (recommended)',
    },
  ])

  assert.deepEqual(
    models.map((model) => model.label),
    [
      'Sonnet 5',
      'Fable 5.1',
      'Opus 5 (1M context)',
      'Opus 4.8',
      'Haiku 4.5',
      'Default (recommended)',
    ],
  )
})

test('Claude catalog reports bounded truncation and successful empty snapshots', () => {
  const items = Array.from({ length: 5 }, (_, index) => ({
    value: `claude-${index}`, displayName: `Claude ${index}`, description: '',
  }))
  const bounded = normalizeClaudeCatalog(items, { maximum: 2 })
  assert.equal(bounded.truncated, true)
  assert.deepEqual(bounded.models.map((model) => model.id), ['claude-0', 'claude-1'])
  assert.deepEqual(normalizeClaudeCatalog([]), { models: [], truncated: false })
})

test('Claude terminal model usage supplies the authoritative context window for aliases', () => {
  const usage = claudeResultContextUsage({
    modelUsage: {
      'claude-sonnet-5': {
        inputTokens: 5_000, cacheReadInputTokens: 0, cacheCreationInputTokens: 0,
        contextWindow: 200_000,
      },
      'claude-opus-4-8[1m]': {
        inputTokens: 40_000, cacheReadInputTokens: 10_000, cacheCreationInputTokens: 2_000,
        contextWindow: 1_000_000,
      },
    },
  }, {
    fallbackTokens: 61_234,
    preferredModel: 'claude-opus-4-8[1m]',
  })

  assert.deepEqual(usage, {
    contextTokens: 61_234,
    contextWindow: 1_000_000,
    model: 'claude-opus-4-8[1m]',
  })
  assert.equal(claudeResultContextUsage({ modelUsage: {} }), null)
})

test('Claude terminal usage joins a 1M alias to its canonical serving generation', () => {
  assert.deepEqual(claudeResultContextUsage({
    modelUsage: {
      'opus[1m]': {
        inputTokens: 40_000,
        cacheReadInputTokens: 10_000,
        cacheCreationInputTokens: 2_000,
        contextWindow: 1_000_000,
        canonicalModel: 'claude-opus-5',
      },
    },
  }, {
    fallbackTokens: 61_234,
    preferredModel: 'claude-opus-5',
  }), {
    contextTokens: 61_234,
    contextWindow: 1_000_000,
    model: 'claude-opus-5',
  })

  assert.equal(claudeResultContextUsage({
    modelUsage: {
      'route-a-opus': {
        inputTokens: 10, contextWindow: 1_000_000,
        canonicalModel: 'claude-opus-5[1m]',
      },
      'route-b-opus': {
        inputTokens: 10, contextWindow: 1_000_000,
        canonicalModel: 'claude-opus-5[1m]',
      },
    },
  }, { preferredModel: 'claude-opus-5' }), null,
  'an ambiguous base-model join fails closed')

  assert.equal(claudeResultContextUsage({
    modelUsage: {
      'first-party-route': {
        inputTokens: 10, contextWindow: 200_000,
        canonicalModel: 'claude-opus-5',
      },
      'gateway-route': {
        inputTokens: 10, contextWindow: 1_000_000,
        canonicalModel: 'claude-opus-5',
      },
    },
  }, { preferredModel: 'claude-opus-5' }), null,
  'a canonical id shared by multiple result rows is not an exact join')
})

test('Claude catalog path fields share an explicit 4096-character validation contract', () => {
  assert.equal(MODEL_CATALOG_LIMITS.scopeCharacters, 4096)
  const maximum = `/${'a'.repeat(MODEL_CATALOG_LIMITS.scopeCharacters - 1)}`
  assert.equal(validatedCatalogScope(maximum), maximum)
  assert.equal(validatedCatalogCwd('/tmp/workspace'), '/tmp/workspace')
  assert.throws(
    () => validatedCatalogScope(`${maximum}x`),
    /scope exceeds 4096 characters/i,
  )
  assert.throws(() => validatedCatalogCwd('/tmp/bad\u0000path'), /control characters/i)
  assert.throws(() => validatedCatalogCwd(' /tmp/workspace '), /surrounding whitespace/i)
})

test('Claude catalog scheduler coalesces equal scopes, serializes distinct scopes, and caps fan-out', async () => {
  const execute = createKeyedSerialExecutor({ maximumPendingKeys: 2 })
  let active = 0
  let peak = 0
  let releases = []
  let starts = []
  const operation = (key) => async () => {
    starts.push(key)
    active += 1
    peak = Math.max(peak, active)
    await new Promise((resolve) => { releases.push(resolve) })
    active -= 1
    return `${key}-result`
  }

  const first = execute('/one', operation('one'))
  const coalesced = execute('/one', () => { throw new Error('must not run') })
  const second = execute('/two', operation('two'))
  await assert.rejects(execute('/three', operation('three')), /maximum 2/i)
  await waitFor(() => releases.length === 1, 'first serialized catalog operation')
  assert.deepEqual(starts, ['one'])
  releases.shift()()
  assert.equal(await first, 'one-result')
  assert.equal(await coalesced, 'one-result')
  await waitFor(() => releases.length === 1, 'second serialized catalog operation')
  assert.deepEqual(starts, ['one', 'two'])
  releases.shift()()
  assert.equal(await second, 'two-result')
  assert.equal(peak, 1)
})

test('Codex catalog pagination filters hidden rows, deduplicates, and retains provider default', async () => {
  const requested = []
  const models = await collectCodexCatalog(async (cursor) => {
    requested.push(cursor)
    if (cursor === null) {
      return {
        data: [
          { id: 'gpt-a', displayName: 'GPT A', hidden: false,
            supportedReasoningEfforts: [
              { reasoningEffort: 'high' }, { reasoningEffort: 'ultra' },
            ] },
          { id: 'gpt-hidden', hidden: true },
        ],
        nextCursor: 'page-2',
      }
    }
    return {
      data: [
        { model: 'gpt-a', isDefault: true,
          supportedReasoningEfforts: [{ reasoningEffort: 'low' }] },
        { id: 'gpt-b', displayName: 'GPT B' },
      ],
      nextCursor: null,
    }
  })

  assert.deepEqual(requested, [null, 'page-2'])
  assert.deepEqual(models.map((model) => model.id), ['gpt-a', 'gpt-b'])
  assert.equal(models[0].isDefault, true)
  assert.deepEqual(models[0].efforts, ['low', 'high', 'ultra'])
  assert.deepEqual(models[0].capabilities, ['effort', 'ultra'])
})

test('Codex catalog rejects repeated cursors, page overflow, and model overflow', async () => {
  await assert.rejects(
    collectCodexCatalog(async () => ({ data: [], nextCursor: 'same' })),
    /repeated.*cursor/i,
  )
  let page = 0
  await assert.rejects(
    collectCodexCatalog(async () => ({ data: [], nextCursor: `page-${++page}` }),
      { pageLimit: 2 }),
    /exceeded 2 pages/i,
  )
  await assert.rejects(
    collectCodexCatalog(async () => ({
      data: [{ id: 'one' }, { id: 'two' }], nextCursor: null,
    }), { modelLimit: 1 }),
    /more than 1 selectable models/i,
  )
})

test('OpenAI catalog leads with described models and drops other modalities', () => {
  const models = normalizeOpenAICatalog([
    { id: 'text-embedding-3-large' },
    { id: 'gpt-5-mini' },
    { id: 'gpt-5.6' },
    { id: 'gpt-5.6' },
  ])
  assert.deepEqual(models.map((model) => model.id), ['gpt-5.6', 'gpt-5-mini'])
  assert.ok(models.every((model) => model.capabilities.includes('effort')))
})

// The bug this replaces: the account's catalog was intersected with a hardcoded list, so an
// account carrying the whole 5.6 generation showed a picker that stopped at 5.5, and no
// configuration change could reach the rest. A released build must not be the prerequisite for
// selecting a model the account already has.
test('OpenAI catalog offers models this build has never heard of', () => {
  const models = normalizeOpenAICatalog([
    { id: 'gpt-5.5' },
    { id: 'gpt-5.6-sol' },
    { id: 'gpt-5.6-terra' },
    { id: 'gpt-5.7-unreleased' },
  ])
  assert.deepEqual(
    models.map((model) => model.id),
    ['gpt-5.5', 'gpt-5.7-unreleased', 'gpt-5.6-terra', 'gpt-5.6-sol'])
  assert.equal(models.find((model) => model.id === 'gpt-5.6-sol').label, 'GPT-5.6 Sol')
  assert.ok(models.every((model) => model.capabilities.includes('effort')))
})

test('OpenAI catalog withholds surfaces the Responses lane cannot drive', () => {
  const models = normalizeOpenAICatalog([
    { id: 'gpt-5.6-audio-preview' },
    { id: 'gpt-realtime-2026-01-01' },
    { id: 'gpt-image-2' },
    { id: 'gpt-4o-transcribe' },
    { id: 'omni-moderation-latest' },
    { id: 'dall-e-4' },
    { id: 'text-embedding-4' },
    { id: 'gpt-5.6-sol' },
  ])
  assert.deepEqual(models.map((model) => model.id), ['gpt-5.6-sol'])
})

test('OpenAI catalog collapses a dated snapshot onto the alias it duplicates', () => {
  const aliased = normalizeOpenAICatalog([
    { id: 'gpt-5.6-sol' },
    { id: 'gpt-5.6-sol-2026-08-01' },
  ])
  assert.deepEqual(aliased.map((model) => model.id), ['gpt-5.6-sol'])

  // With no alias beside it the snapshot is the only way to reach that model, so it stays.
  const orphaned = normalizeOpenAICatalog([{ id: 'gpt-5.6-sol-2026-08-01' }])
  assert.deepEqual(orphaned.map((model) => model.id), ['gpt-5.6-sol-2026-08-01'])
})

test('OpenAI catalog orders a two-digit minor version above a single-digit one', () => {
  const models = normalizeOpenAICatalog([{ id: 'gpt-5.9-x' }, { id: 'gpt-5.10-x' }])
  assert.deepEqual(models.map((model) => model.id), ['gpt-5.10-x', 'gpt-5.9-x'])
})

test('OpenAI catalog request sends only its credential and accepts empty provider results', async () => {
  let observed
  const models = await fetchOpenAIModelCatalog({
    baseURL: 'https://example.invalid/v1/',
    apiKey: 'secret-key',
    fetchImpl: async (url, options) => {
      observed = { url, options }
      return jsonResponse({ data: [] })
    },
  })
  assert.deepEqual(models, [])
  assert.equal(observed.url, 'https://example.invalid/v1/models')
  assert.deepEqual(observed.options.headers, { Authorization: 'Bearer secret-key' })
  assert.equal(observed.options.method, 'GET')
})

test('OpenAI catalog request rejects provider errors, oversized bodies, invalid JSON, and timeout', async () => {
  await assert.rejects(fetchOpenAIModelCatalog({
    baseURL: 'https://example.invalid/v1', apiKey: 'key',
    fetchImpl: async () => jsonResponse({}, { status: 401 }),
  }), /failed \(401\)/i)

  await assert.rejects(fetchOpenAIModelCatalog({
    baseURL: 'https://example.invalid/v1', apiKey: 'key', responseLimit: 10,
    fetchImpl: async () => jsonResponse({ data: [] }, { contentLength: '100' }),
  }), /too large/i)

  let reads = 0
  let cancelled = false
  await assert.rejects(fetchOpenAIModelCatalog({
    baseURL: 'https://example.invalid/v1', apiKey: 'key', responseLimit: 10,
    fetchImpl: async () => ({
      ok: true, status: 200, headers: { get: () => null },
      body: { getReader: () => ({
        read: async () => reads++ < 2
          ? { done: false, value: new Uint8Array(6) }
          : { done: true },
        cancel: async () => { cancelled = true },
        releaseLock: () => {},
      }) },
    }),
  }), /too large/i)
  assert.equal(cancelled, true)

  await assert.rejects(fetchOpenAIModelCatalog({
    baseURL: 'https://example.invalid/v1', apiKey: 'key',
    fetchImpl: async () => ({
      ok: true, status: 200, headers: { get: () => null },
      arrayBuffer: async () => new TextEncoder().encode('{bad json').buffer,
    }),
  }), /invalid JSON/i)

  await assert.rejects(fetchOpenAIModelCatalog({
    baseURL: 'https://example.invalid/v1', apiKey: 'key', timeoutMilliseconds: 5,
    fetchImpl: async (_url, { signal }) => await new Promise((resolve, reject) => {
      signal.addEventListener('abort', () => {
        const error = new Error('aborted')
        error.name = 'AbortError'
        reject(error)
      })
    }),
  }), /timed out/i)
})

test('OpenAI agentd emits only provider-reported compatible models and echoes request ownership', async (t) => {
  const requests = []
  const server = http.createServer((request, response) => {
    requests.push({ url: request.url, authorization: request.headers.authorization })
    response.setHeader('content-type', 'application/json')
    response.end(JSON.stringify({ data: [
      { id: 'gpt-5-mini' }, { id: 'text-embedding-3-large' }, { id: 'gpt-5.6' },
    ] }))
  })
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve))
  t.after(() => server.close())
  const address = server.address()
  const fixture = startAgentd(t, {
    provider: 'openai', key: 'fixture-openai-key',
    baseURL: `http://127.0.0.1:${address.port}/v1`,
  })

  await waitFor(() => fixture.events.find((event) => event.type === 'ready'), 'OpenAI ready')
  const automatic = await waitFor(
    () => fixture.events.find((event) => event.type === 'model_catalog' && event.id === undefined),
    'automatic OpenAI catalog',
  )
  assert.equal(automatic.scope, '')
  assert.deepEqual(automatic.models.map((model) => model.id), ['gpt-5.6', 'gpt-5-mini'])
  assert.equal(requests[0].url, '/v1/models')
  assert.equal(requests[0].authorization, 'Bearer fixture-openai-key')

  fixture.child.stdin.write(`${JSON.stringify({
    type: 'model_catalog', id: 'openai-catalog', cwd: fixture.config, scope: 'ignored',
  })}\n`)
  const requested = await waitFor(
    () => fixture.events.find((event) => event.type === 'model_catalog'
      && event.id === 'openai-catalog'),
    'requested OpenAI catalog',
  )
  assert.equal(requested.scope, '')
  assert.deepEqual(requested.models, automatic.models)

  fixture.child.stdin.write(`${JSON.stringify({
    type: 'provider_capabilities', id: 'openai-capabilities',
    scope: 'ignored', model: 'gpt-5.6', workspacePolicyRevision: 7,
  })}\n`)
  let capabilities
  try {
    capabilities = await waitFor(
      () => fixture.events.find((event) => event.type === 'provider_capabilities'
        && event.id === 'openai-capabilities'),
      'requested OpenAI capabilities',
    )
  } catch (error) {
    assert.fail(`${error.message}; events: ${JSON.stringify(fixture.events)}; agentd stderr: ${fixture.errors.join('')}`)
  }
  assert.equal(capabilities.scope, '')
  assert.equal(capabilities.model, 'gpt-5.6')
  assert.match(capabilities.adapterRevision, /^provider-capabilities-/)
  assert.match(capabilities.rawEvidenceDigest, /^[a-f0-9]{64}$/)
  assert.deepEqual(capabilities.capabilities.map((item) => item.id), ['reasoning_effort'])
  assert.equal(capabilities.capabilities[0].providerAvailability, 'unknown')
  assert.equal(capabilities.capabilities[0].mechanicianSupport, 'implemented')

  fixture.child.stdin.write(`${JSON.stringify({
    type: 'provider_capabilities', id: 'missing-capabilities',
    scope: '', model: 'not-in-the-catalog',
  })}\n`)
  const capabilityFailure = await waitFor(
    () => fixture.events.find((event) => event.type === 'provider_capabilities_error'
      && event.id === 'missing-capabilities'),
    'missing-model capability error',
  )
  assert.equal(capabilityFailure.model, 'not-in-the-catalog')
  assert.match(capabilityFailure.message, /not present in the current provider catalog/i)
})

test('unconfigured Anthropic catalog request preserves its requested scope in a terminal error', async (t) => {
  const fixture = startAgentd(t, { provider: 'anthropic', disabled: true })
  await waitFor(() => fixture.events.find((event) => event.type === 'ready'), 'Anthropic ready')
  fixture.child.stdin.write(`${JSON.stringify({
    type: 'model_catalog', id: 'claude-catalog', cwd: fixture.config, scope: fixture.config,
  })}\n`)
  const failure = await waitFor(
    () => fixture.events.find((event) => event.type === 'model_catalog_error'
      && event.id === 'claude-catalog'),
    'Anthropic catalog error',
  )
  assert.equal(failure.scope, fixture.config)
  assert.match(failure.message, /disconnected from Mechanician/i)
})

test('explicit Anthropic catalog request rejects an invalid cwd under its original scope', async (t) => {
  const fixture = startAgentd(t, { provider: 'anthropic', disabled: true })
  await waitFor(() => fixture.events.find((event) => event.type === 'ready'), 'Anthropic ready')
  const missing = path.join(fixture.config, 'missing-workspace')
  fixture.child.stdin.write(`${JSON.stringify({
    type: 'model_catalog', id: 'invalid-claude-cwd', cwd: missing, scope: missing,
  })}\n`)
  const failure = await waitFor(
    () => fixture.events.find((event) => event.type === 'model_catalog_error'
      && event.id === 'invalid-claude-cwd'),
    'invalid Anthropic cwd error',
  )
  assert.equal(failure.scope, missing)
  assert.match(failure.message, /cwd is not an existing directory/i)
  assert.equal(fixture.events.some((event) => event.type === 'model_catalog'
    && event.id === 'invalid-claude-cwd'), false)
})

test('explicit Anthropic catalog request does not truncate an overlong scope identity', async (t) => {
  const fixture = startAgentd(t, { provider: 'anthropic', disabled: true })
  await waitFor(() => fixture.events.find((event) => event.type === 'ready'), 'Anthropic ready')
  const overlong = `/${'x'.repeat(MODEL_CATALOG_LIMITS.scopeCharacters)}`
  fixture.child.stdin.write(`${JSON.stringify({
    type: 'model_catalog', id: 'overlong-claude-scope', cwd: fixture.config, scope: overlong,
  })}\n`)
  const failure = await waitFor(
    () => fixture.events.find((event) => event.type === 'model_catalog_error'
      && event.id === 'overlong-claude-scope'),
    'overlong Anthropic scope error',
  )
  assert.equal(failure.scope, '')
  assert.match(failure.message, /scope exceeds 4096 characters/i)
})
