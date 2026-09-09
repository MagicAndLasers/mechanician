import assert from 'node:assert/strict'
import fs from 'node:fs'
import http from 'node:http'
import os from 'node:os'
import path from 'node:path'
import { spawn } from 'node:child_process'
import { fileURLToPath } from 'node:url'
import { test } from 'node:test'

import { HELP_EXPERT_TOOL_PROFILE } from '../src/codex-tools.mjs'

const here = path.dirname(fileURLToPath(import.meta.url))
const agentd = path.resolve(here, '../src/agentd.mjs')

const delay = (milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds))

async function waitFor(predicate, description, fixture, timeout = 5000) {
  const deadline = Date.now() + timeout
  while (Date.now() < deadline) {
    const value = predicate()
    if (value) return value
    await delay(10)
  }
  assert.fail(`timed out waiting for ${description}\nagentd stderr:\n${fixture.stderr}`)
}

function send(child, request) {
  child.stdin.write(`${JSON.stringify(request)}\n`)
}

function sendJSON(res, status, body, headers = {}) {
  res.writeHead(status, { 'Content-Type': 'application/json', ...headers })
  res.end(JSON.stringify(body))
}

function sendSSE(res, events, headers = {}) {
  res.writeHead(200, { 'Content-Type': 'text/event-stream', ...headers })
  for (const event of events) res.write(`data: ${JSON.stringify(event)}\n\n`)
  res.end()
}

async function startFixture(
  t,
  respond,
  { apiKey = 'sk-test-not-a-real-key', preventKeychain = false, environment = {} } = {},
) {
  const requests = []
  const server = http.createServer(async (req, res) => {
    // Agentd now refreshes the route-owned model catalog when an OpenAI lane becomes
    // ready. Keep these turn/error fixtures focused on Responses requests; catalog
    // behavior has its own deterministic integration coverage in model-catalog.test.
    if (req.method === 'GET' && req.url === '/v1/models') {
      sendJSON(res, 200, { data: [] })
      return
    }
    let raw = ''
    for await (const chunk of req) raw += chunk
    let body = null
    try { body = JSON.parse(raw) } catch {}
    const request = { method: req.method, url: req.url, headers: req.headers, body }
    requests.push(request)
    try { await respond(req, res, request) }
    catch (error) {
      if (!res.destroyed) res.destroy(error)
    }
  })
  await new Promise((resolve, reject) => {
    server.once('error', reject)
    server.listen(0, '127.0.0.1', resolve)
  })

  const config = fs.mkdtempSync(path.join(os.tmpdir(), 'mechanician-openai-errors-'))
  const address = server.address()
  const child = spawn(process.execPath, [agentd], {
    env: {
      ...process.env,
      MECHANICIAN_PROVIDER: 'openai',
      MECHANICIAN_CONFIG_DIR: config,
      MECHANICIAN_CWD: config,
      OPENAI_API_KEY: apiKey,
      OPENAI_BASE_URL: `http://127.0.0.1:${address.port}/v1`,
      ANTHROPIC_API_KEY: '',
      ...(preventKeychain ? { PATH: config } : {}),
      ...environment,
    },
    stdio: ['pipe', 'pipe', 'pipe'],
  })
  const events = []
  let buffered = ''
  let stderr = ''
  child.stdout.setEncoding('utf8')
  child.stderr.setEncoding('utf8')
  child.stdout.on('data', (chunk) => {
    buffered += chunk
    const lines = buffered.split('\n')
    buffered = lines.pop() ?? ''
    for (const line of lines) if (line) events.push(JSON.parse(line))
  })
  child.stderr.on('data', (chunk) => { stderr += chunk })
  const fixture = {
    child,
    events,
    requests,
    get stderr() { return stderr },
  }
  t.after(async () => {
    if (child.exitCode == null) child.kill()
    server.closeAllConnections?.()
    await new Promise((resolve) => server.close(resolve))
    fs.rmSync(config, { recursive: true, force: true })
  })
  await waitFor(() => events.find((event) => event.type === 'ready'), 'OpenAI ready event', fixture)
  return fixture
}

test('missing OpenAI API key emits a normalized authentication failure instead of mock output', async (t) => {
  const fixture = await startFixture(t, () => {
    assert.fail('a missing API key must fail before any HTTP request')
  }, { apiKey: '', preventKeychain: true })

  const terminal = await runTurn(fixture)
  assert.deepEqual(terminal, {
    type: 'error',
    id: 'turn-1',
    errorKind: 'authentication',
    provider: 'openai',
    message: 'OpenAI API key is not configured. Add it in Settings → Account.',
    access: 'openai_api',
    providerError: {
      code: 'missing_api_key',
      providerType: 'authentication_error',
      status: 401,
    },
  })
  assert.equal(fixture.requests.length, 0)
  assert.equal(fixture.events.some((event) => event.type === 'delta' && event.id === 'turn-1'), false)
  assert.equal(fixture.events.some(
    (event) => event.type === 'tool_surface' && event.id === 'turn-1'), false)
})

test('managed unattended disable returns an OpenAI WaitFor error without arming a wait', async (t) => {
  const fixture = await startFixture(t, (_req, res) => {
    if (fixture.requests.length === 1) {
      sendSSE(res, [
        {
          type: 'response.output_item.done',
          item: {
            type: 'function_call', call_id: 'managed-wait-call', name: 'WaitFor',
            arguments: JSON.stringify({
              note: 'managed wait probe', check: 'exit 0', after: '1s', everySeconds: 10,
            }),
          },
        },
        { type: 'response.completed', response: { id: 'managed-wait-response-1', output: [] } },
      ])
      return
    }
    sendSSE(res, [
      { type: 'response.output_text.delta', delta: 'The managed policy disabled waiting.' },
      { type: 'response.completed', response: { id: 'managed-wait-response-2', output: [] } },
    ])
  }, {
    environment: {
      MECHANICIAN_MANAGED_POLICY: '1',
      MECHANICIAN_ALLOWED_PROVIDER_ACCESSES: 'openai_api',
      MECHANICIAN_ALLOW_USER_EXTENSIONS: '1',
      MECHANICIAN_ALLOW_UNATTENDED_TASKS: '0',
    },
  })

  const terminal = await runTurn(fixture, 'managed-openai-wait-disabled', {
    permissionMode: 'bypassPermissions',
  })
  assert.deepEqual(terminal, { type: 'done', id: 'managed-openai-wait-disabled' })
  assert.equal(fixture.requests.length, 2)
  const functionOutput = fixture.requests[1].body.input.find(
    (item) => item.type === 'function_call_output' && item.call_id === 'managed-wait-call')
  assert.match(functionOutput?.output || '', /disabled by managed enterprise policy/)
  assert.deepEqual(fixture.events.find((event) => event.type === 'tool_result'
    && event.id === 'managed-openai-wait-disabled'), {
    type: 'tool_result', id: 'managed-openai-wait-disabled', toolUseId: 'managed-wait-call',
    result: 'WaitFor is disabled by managed enterprise policy. No wait was armed.', status: 'error',
  })
  assert.equal(fixture.events.some((event) => event.type === 'waiting'
    && event.id === 'managed-openai-wait-disabled'), false)
  assert.equal(fixture.events.some((event) => event.type === 'permission_request'
    && event.id === 'managed-openai-wait-disabled'), false)
})

test('requested Plan withholds and denies OpenAI operations under managed and ordinary policy',
  async (t) => {
  for (const managed of [false, true]) {
  const fixture = await startFixture(t, (_req, res) => {
    const ordinal = Math.floor((fixture.requests.length - 1) / 2)
    if (fixture.requests.length % 2 === 1) {
      sendSSE(res, [
        {
          type: 'response.output_item.done',
          item: {
            type: 'function_call', call_id: `managed-operate-call-${ordinal}`,
            name: 'OperateMechanician',
            arguments: JSON.stringify({ operation: 'focusComposer' }),
          },
        },
        {
          type: 'response.completed',
          response: { id: `managed-operate-response-${ordinal}-1`, output: [] },
        },
      ])
      return
    }
    sendSSE(res, [
      { type: 'response.output_text.delta', delta: 'The managed Plan ceiling prevented operation.' },
      {
        type: 'response.completed',
        response: { id: `managed-operate-response-${ordinal}-2`, output: [] },
      },
    ])
  }, managed ? {
    environment: {
      MECHANICIAN_MANAGED_POLICY: '1',
      MECHANICIAN_MAX_PERMISSION_MODE: 'default',
      MECHANICIAN_ALLOWED_PROVIDER_ACCESSES: 'openai_api',
      MECHANICIAN_ALLOW_USER_EXTENSIONS: '1',
      MECHANICIAN_ALLOW_UNATTENDED_TASKS: '1',
    },
  } : {})

  const cases = [
    { id: `${managed ? 'managed' : 'ordinary'}-openai-standard-requested-plan`, toolProfile: 'standard' },
    { id: `${managed ? 'managed' : 'ordinary'}-openai-help-requested-plan`, toolProfile: HELP_EXPERT_TOOL_PROFILE },
  ]
  for (let ordinal = 0; ordinal < cases.length; ordinal += 1) {
    const { id, toolProfile } = cases[ordinal]
    const terminal = await runTurn(fixture, id, { permissionMode: 'plan', toolProfile })
    assert.deepEqual(terminal, { type: 'done', id })
    const toolNames = fixture.requests[ordinal * 2].body.tools.map((tool) => tool.name)
    assert.equal(toolNames.includes('OperateMechanician'), false)
    if (toolProfile === HELP_EXPERT_TOOL_PROFILE) {
      assert.deepEqual(toolNames, ['SearchMechanicianHelp', 'ShowMechanician'])
    }
    const callId = `managed-operate-call-${ordinal}`
    const functionOutput = fixture.requests[ordinal * 2 + 1].body.input.find(
      (item) => item.type === 'function_call_output' && item.call_id === callId)
    assert.match(functionOutput?.output || '', /unavailable while this conversation is in Plan mode/)
    assert.deepEqual(fixture.events.find((event) => event.type === 'tool_result'
      && event.id === id), {
      type: 'tool_result', id, toolUseId: callId,
      result: 'OperateMechanician is unavailable while this conversation is in Plan mode.',
      status: 'error',
    })
    assert.equal(fixture.events.some((event) => event.type === 'operate_mechanician_request'
      && event.id === id), false)
  }
  }
})

async function runTurn(fixture, id = 'turn-1', overrides = {}) {
  send(fixture.child, {
    type: 'send', id, prompt: 'fixture prompt', model: 'gpt-test', ...overrides,
  })
  const terminal = await waitFor(
    () => fixture.events.find((event) => event.id === id && (event.type === 'error' || event.type === 'done')),
    `${id} terminal event`,
    fixture,
  )
  await delay(30)
  assert.equal(
    fixture.events.filter((event) => event.id === id && (event.type === 'error' || event.type === 'done')).length,
    1,
    'a turn must emit exactly one terminal event',
  )
  return terminal
}

test('OpenAI HTTP authentication failure retains safe diagnostics and one terminal error', async (t) => {
  const fixture = await startFixture(t, (_req, res) => {
    sendJSON(res, 401, {
      error: {
        message: 'Incorrect API key sk-proj-abcdefghijklmnop provided.',
        type: 'invalid_request_error',
        code: 'invalid_api_key',
        param: 'api_key',
        private: { prompt: 'must not survive' },
      },
    }, { 'X-Request-Id': 'req_auth_1' })
  })

  const terminal = await runTurn(fixture)
  assert.deepEqual(terminal, {
    type: 'error',
    id: 'turn-1',
    errorKind: 'authentication',
    provider: 'openai',
    message: 'Incorrect API key [redacted-api-key] provided.',
    access: 'openai_api',
    providerError: {
      code: 'invalid_api_key',
      providerType: 'invalid_request_error',
      param: 'api_key',
      status: 401,
      requestId: 'req_auth_1',
      clientRequestId: fixture.requests[0].headers['x-client-request-id'],
    },
  })
  assert.match(fixture.requests[0].headers['x-client-request-id'], /^[\x20-\x7e]{1,512}$/)
  assert.doesNotMatch(JSON.stringify(terminal), /abcdefghijklmnop|must not survive/)
  assert.equal(fixture.events.some(
    (event) => event.type === 'tool_surface' && event.id === 'turn-1'), false)
})

test('OpenAI quota 429 remains distinct from request throttling and retains rate headers', async (t) => {
  const fixture = await startFixture(t, (_req, res) => {
    sendJSON(res, 429, {
      error: {
        message: 'You exceeded your current quota.',
        type: 'insufficient_quota',
        code: 'insufficient_quota',
        arbitrary: 'omit this',
      },
    }, {
      'X-Request-Id': 'req_quota_1',
      'Retry-After': '2.5',
      'X-RateLimit-Limit-Requests': '500',
      'X-RateLimit-Remaining-Requests': '0',
      'X-RateLimit-Reset-Requests': '750ms',
      'X-RateLimit-Limit-Tokens': '30000',
      'X-RateLimit-Remaining-Tokens': '12',
      'X-RateLimit-Reset-Tokens': '1m2s',
      'X-RateLimit-Limit-Project-Tokens': '60000',
      'X-RateLimit-Remaining-Project-Tokens': '24000',
      'X-RateLimit-Reset-Project-Tokens': '2m',
    })
  })

  const terminal = await runTurn(fixture)
  assert.equal(terminal.errorKind, 'quota')
  assert.equal(terminal.providerError.status, 429)
  assert.equal(terminal.providerError.requestId, 'req_quota_1')
  assert.equal(terminal.providerError.retryAfterSeconds, 2.5)
  assert.deepEqual(terminal.providerError.rateLimits, {
    requests: { limit: 500, remaining: 0, resetAfterSeconds: 0.75 },
    tokens: { limit: 30000, remaining: 12, resetAfterSeconds: 62 },
    project: { limit: 60000, remaining: 24000, resetAfterSeconds: 120 },
  })
  assert.doesNotMatch(JSON.stringify(terminal), /omit this/)
})

test('OpenAI response.failed SSE preserves context-limit metadata', async (t) => {
  const fixture = await startFixture(t, (_req, res) => {
    sendSSE(res, [{
      type: 'response.failed',
      response: {
        id: 'resp_failed_1',
        error: {
          message: 'Input exceeds the model context window.',
          type: 'invalid_request_error',
          code: 'context_length_exceeded',
          param: 'input',
          details: { transcript: 'private content' },
        },
      },
    }], { 'X-Request-Id': 'req_stream_failed_1' })
  })

  const terminal = await runTurn(fixture)
  assert.equal(terminal.errorKind, 'context_limit')
  assert.equal(terminal.providerError.code, 'context_length_exceeded')
  assert.equal(terminal.providerError.providerType, 'invalid_request_error')
  assert.equal(terminal.providerError.param, 'input')
  assert.equal(terminal.providerError.requestId, 'req_stream_failed_1')
  assert.doesNotMatch(JSON.stringify(terminal), /private content|details/)
})

test('OpenAI response.incomplete SSE is terminal and retains its public reason only', async (t) => {
  const fixture = await startFixture(t, (_req, res) => {
    sendSSE(res, [{
      type: 'response.incomplete',
      response: {
        id: 'resp_incomplete_1',
        incomplete_details: { reason: 'max_output_tokens', private: 'omit this' },
      },
    }])
  })

  const terminal = await runTurn(fixture)
  assert.equal(terminal.errorKind, 'output_limit')
  assert.equal(terminal.message, 'The response reached its output token limit.')
  assert.doesNotMatch(JSON.stringify(terminal), /omit this|private/)
})

test('OpenAI error SSE retains code and param without arbitrary event fields', async (t) => {
  const fixture = await startFixture(t, (_req, res) => {
    sendSSE(res, [{
      type: 'error',
      code: 'invalid_request_error',
      message: 'The selected option is invalid.',
      param: 'reasoning.effort',
      secret: 'must not survive',
    }])
  })

  const terminal = await runTurn(fixture)
  assert.equal(terminal.errorKind, 'invalid_request')
  assert.equal(terminal.providerError.code, 'invalid_request_error')
  assert.equal(terminal.providerError.param, 'reasoning.effort')
  assert.equal(Object.hasOwn(terminal.providerError, 'providerType'), false)
  assert.doesNotMatch(JSON.stringify(terminal), /must not survive|secret/)
})

test('premature OpenAI stream EOF is a network error, never a false done', async (t) => {
  const fixture = await startFixture(t, (_req, res) => {
    sendSSE(res, [{ type: 'response.output_text.delta', delta: 'partial answer' }], {
      'X-Request-Id': 'req_eof_1',
    })
  })

  const terminal = await runTurn(fixture)
  assert.equal(fixture.events.some((event) => event.type === 'delta' && event.text === 'partial answer'), true)
  assert.equal(terminal.type, 'error')
  assert.equal(terminal.errorKind, 'network')
  assert.equal(terminal.providerError.code, 'response_stream_disconnected')
  assert.equal(terminal.providerError.requestId, 'req_eof_1')
  assert.equal(fixture.events.some((event) => event.type === 'done' && event.id === 'turn-1'), false)
})

test('abrupt OpenAI response-body disconnect is normalized as a network error', async (t) => {
  const fixture = await startFixture(t, (_req, res) => {
    res.writeHead(200, { 'Content-Type': 'text/event-stream', 'X-Request-Id': 'req_disconnect_1' })
    res.flushHeaders()
    res.write(`data: ${JSON.stringify({ type: 'response.output_text.delta', delta: 'partial' })}\n\n`)
    setTimeout(() => res.destroy(), 20)
  })

  const terminal = await runTurn(fixture)
  assert.equal(terminal.errorKind, 'network')
  assert.equal(terminal.providerError.code, 'response_stream_connection_failed')
  assert.equal(terminal.providerError.requestId, 'req_disconnect_1')
  assert.equal(fixture.events.some((event) => event.type === 'done' && event.id === 'turn-1'), false)
})

test('fetch connection failure is normalized and retains the client request id', async (t) => {
  const fixture = await startFixture(t, (req) => { req.socket.destroy() })

  const terminal = await runTurn(fixture)
  assert.equal(terminal.type, 'error')
  assert.equal(terminal.errorKind, 'network')
  assert.equal(terminal.providerError.clientRequestId, fixture.requests[0].headers['x-client-request-id'])
  assert.equal(Object.hasOwn(terminal.providerError, 'requestId'), false)
})

test('response.completed remains the only successful OpenAI stream terminal', async (t) => {
  const fixture = await startFixture(t, (_req, res) => {
    sendSSE(res, [
      { type: 'response.output_text.delta', delta: 'complete answer' },
      {
        type: 'response.completed',
        response: {
          id: 'resp_complete_1',
          status: 'completed',
          output: [],
          usage: { input_tokens: 12, output_tokens: 4 },
        },
      },
    ], { 'X-Request-Id': 'req_complete_1' })
  })

  const terminal = await runTurn(fixture, 'turn-1', {
    prompt: 'Keep the request body clean.',
    projectInstructions: 'Respond with concise implementation notes.',
    workspaceInstructionsRevision: 'openai-workspace-revision',
  })
  assert.equal(Object.hasOwn(fixture.requests[0].body, 'reasoning'), false)
  assert.match(
    fixture.requests[0].body.instructions,
    /# Workspace Instructions\nRespond with concise implementation notes\./,
  )
  assert.deepEqual(fixture.requests[0].body.input, [{
    role: 'user',
    content: [{ type: 'input_text', text: 'Keep the request body clean.' }],
  }])
  const expectedTools = [
    'Bash',
    'Build',
    'ComputerAction',
    'ComputerScreenshot',
    'CreateOrUpdateArtifact',
    'DiscoverAppActions',
    'Edit',
    'ListCapabilities',
    'ListFiles',
    'ListShortcuts',
    'OperateMechanician',
    'Question',
    'Read',
    'RecommendMechanicianWorkflow',
    'RequestProviderAccess',
    'RunAppleScript',
    'RunCapability',
    'RunShortcut',
    'SearchFiles',
    'SearchMechanicianHelp',
    'ShowMechanician',
    'WaitFor',
    'Write',
  ]
  assert.deepEqual(fixture.requests[0].body.tools.map((tool) => tool.name).sort(), expectedTools)
  const standardSurface = fixture.events.filter((event) => event.type === 'tool_surface'
    && event.id === 'turn-1')
  assert.deepEqual(standardSurface, [{
    type: 'tool_surface', id: 'turn-1', lane: 'openai', toolProfile: 'standard',
    permissionMode: 'default', coverage: 'complete',
    provenance: 'mechanician-api-request', adapterRevision: 'mechanician-tool-surface-v1',
    tools: expectedTools,
  }])
  assert.ok(fixture.events.indexOf(standardSurface[0]) < fixture.events.findIndex(
    (event) => event.id === 'turn-1' && event.type === 'delta'))
  assert.deepEqual(terminal, { type: 'done', id: 'turn-1' })
  assert.equal(fixture.events.some((event) => event.type === 'error' && event.id === 'turn-1'), false)
  assert.deepEqual(
    fixture.events.find((event) => event.type === 'usage' && event.id === 'turn-1'),
    {
      type: 'usage', id: 'turn-1', provenance: 'provider_report', scope: 'request',
      aggregation: 'final', input: 12, output: 4,
    },
  )
  assert.deepEqual(
    fixture.events.find((event) => event.type === 'session' && event.id === 'turn-1'),
    { type: 'session', id: 'turn-1', sessionId: 'resp_complete_1' },
  )
})

test('OpenAI sends exact explicit effort and ignores the legacy hidden Ultra bit', async (t) => {
  const fixture = await startFixture(t, (_req, res) => {
    sendSSE(res, [{
      type: 'response.completed',
      response: { id: `response-${fixture.requests.length}`, status: 'completed', output: [] },
    }])
  })

  await runTurn(fixture, 'provider-default')
  await runTurn(fixture, 'explicit-effort', { effort: 'low' })
  await runTurn(fixture, 'max-effort', { effort: 'max' })
  await runTurn(fixture, 'legacy-ultra', { ultracode: true })

  assert.equal(Object.hasOwn(fixture.requests[0].body, 'reasoning'), false)
  assert.deepEqual(fixture.requests[1].body.reasoning, { effort: 'low' })
  assert.deepEqual(fixture.requests[2].body.reasoning, { effort: 'max' })
  assert.equal(Object.hasOwn(fixture.requests[3].body, 'reasoning'), false)
})

test('response.completed stays successful when the socket fails afterward', async (t) => {
  const fixture = await startFixture(t, (_req, res) => {
    res.writeHead(200, { 'Content-Type': 'text/event-stream', 'X-Request-Id': 'req_complete_disconnect_1' })
    res.flushHeaders()
    res.write(`data: ${JSON.stringify({
      type: 'response.completed',
      response: {
        id: 'resp_complete_disconnect_1',
        status: 'completed',
        output: [],
        usage: { input_tokens: 9, output_tokens: 3 },
      },
    })}\n\n`)
    setTimeout(() => res.destroy(), 20)
  })

  const terminal = await runTurn(fixture)
  assert.deepEqual(terminal, { type: 'done', id: 'turn-1' })
  assert.equal(fixture.events.some((event) => event.type === 'error' && event.id === 'turn-1'), false)
  assert.deepEqual(
    fixture.events.find((event) => event.type === 'usage' && event.id === 'turn-1'),
    {
      type: 'usage', id: 'turn-1', provenance: 'provider_report', scope: 'request',
      aggregation: 'final', input: 9, output: 3,
    },
  )
})

test('one OpenAI daemon runs concurrent turns and interrupts only the targeted turn', async (t) => {
  const streams = new Map()
  const fixture = await startFixture(t, (_req, res, request) => {
    const prompt = request.body?.input?.at(-1)?.content?.find((item) => item.type === 'input_text')?.text
    assert.ok(prompt, 'each OpenAI request must retain its turn prompt')
    res.writeHead(200, { 'Content-Type': 'text/event-stream' })
    res.flushHeaders()
    streams.set(prompt, res)
    res.write(`data: ${JSON.stringify({ type: 'response.output_text.delta', delta: `${prompt}:working` })}\n\n`)
  })

  send(fixture.child, { type: 'send', id: 'turn-interrupt', prompt: 'interrupt me' })
  send(fixture.child, { type: 'send', id: 'turn-survivor', prompt: 'keep going' })
  await waitFor(
    () => streams.size === 2 &&
      fixture.events.some((event) => event.type === 'delta' && event.id === 'turn-interrupt') &&
      fixture.events.some((event) => event.type === 'delta' && event.id === 'turn-survivor'),
    'both concurrent OpenAI streams',
    fixture,
  )
  assert.equal(fixture.requests.length, 2)
  assert.equal(streams.get('interrupt me').writableEnded, false)
  assert.equal(streams.get('keep going').writableEnded, false)

  send(fixture.child, { type: 'interrupt', turnId: 'turn-interrupt' })
  const terminal = await waitFor(
    () => fixture.events.find((event) => event.id === 'turn-interrupt' && (event.type === 'error' || event.type === 'done')),
    'interrupted terminal event',
    fixture,
  )
  await delay(30)

  assert.deepEqual(terminal, { type: 'done', id: 'turn-interrupt', interrupted: true })
  assert.equal(fixture.events.some((event) => event.type === 'error' && event.id === 'turn-interrupt'), false)
  assert.equal(
    fixture.events.filter((event) => event.id === 'turn-interrupt' && (event.type === 'done' || event.type === 'error')).length,
    1,
  )
  assert.equal(
    fixture.events.some((event) => event.id === 'turn-survivor' && (event.type === 'done' || event.type === 'error')),
    false,
    'interrupting one turn must not terminate another turn on the same provider daemon',
  )

  const survivor = streams.get('keep going')
  survivor.write(`data: ${JSON.stringify({ type: 'response.output_text.delta', delta: 'still working' })}\n\n`)
  survivor.write(`data: ${JSON.stringify({
    type: 'response.completed',
    response: { id: 'resp_survivor', status: 'completed', output: [] },
  })}\n\n`)
  survivor.end()

  const survivorTerminal = await waitFor(
    () => fixture.events.find((event) => event.id === 'turn-survivor' && (event.type === 'error' || event.type === 'done')),
    'surviving turn terminal event',
    fixture,
  )
  assert.deepEqual(survivorTerminal, { type: 'done', id: 'turn-survivor' })
  assert.deepEqual(
    fixture.events.filter((event) => event.type === 'delta' && event.id === 'turn-survivor').map((event) => event.text),
    ['keep going:working', 'still working'],
  )
  assert.equal(
    fixture.events.filter((event) => event.id === 'turn-survivor' && (event.type === 'done' || event.type === 'error')).length,
    1,
  )
})
