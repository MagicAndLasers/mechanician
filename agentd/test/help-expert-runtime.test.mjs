import assert from 'node:assert/strict'
import { once } from 'node:events'
import fs from 'node:fs'
import http from 'node:http'
import os from 'node:os'
import path from 'node:path'
import { spawn } from 'node:child_process'
import { fileURLToPath } from 'node:url'
import { test } from 'node:test'

import { CLOSED_PROFILE_DISABLED_CODEX_FEATURES } from '../src/codex-tools.mjs'
import {
  HELP_EXPERT_CWD,
  HELP_EXPERT_GUIDANCE,
  HELP_EXPERT_PERMISSION_PROFILE,
  HELP_EXPERT_TOOL_PROFILE,
  codexDynamicToolNames,
} from '../src/codex-tools.mjs'

const here = path.dirname(fileURLToPath(import.meta.url))
const agentd = path.resolve(here, '../src/agentd.mjs')
const permissionModes = ['default', 'acceptEdits', 'bypassPermissions', 'plan']

async function waitFor(predicate, description, fixture, timeout = 12_000) {
  const deadline = Date.now() + timeout
  while (Date.now() < deadline) {
    const value = predicate()
    if (value) return value
    await new Promise((resolve) => setTimeout(resolve, 10))
  }
  assert.fail(`timed out waiting for ${description}\nagentd stderr:\n${fixture.stderr}`)
}

function observe(child) {
  const events = []
  let buffered = ''
  let stderr = ''
  child.stdout.setEncoding('utf8')
  child.stdout.on('data', (chunk) => {
    buffered += chunk
    const lines = buffered.split('\n')
    buffered = lines.pop() ?? ''
    for (const line of lines) if (line) events.push(JSON.parse(line))
  })
  child.stderr.setEncoding('utf8')
  child.stderr.on('data', (chunk) => { stderr += chunk })
  return { child, events, get stderr() { return stderr } }
}

function cleanUpChild(t, fixture, directory) {
  t.after(async () => {
    if (fixture.child.exitCode === null) fixture.child.kill('SIGKILL')
    if (fixture.child.exitCode === null) {
      try { await once(fixture.child, 'exit') } catch {}
    }
    fs.rmSync(directory, { recursive: true, force: true })
  })
}

function writeClaudeLoader(directory, capturePath) {
  const sdk = `
    import fs from 'node:fs'
    const capturePath = ${JSON.stringify(capturePath)}
    let session = 0

    export function createSdkMcpServer(config) { return config }
    export function tool(name, description, schema, handler) {
      return { name, description, schema, handler }
    }
    export function query({ prompt, options }) {
      return (async function* () {
        const input = prompt?.[Symbol.asyncIterator]?.()
        if (input) await input.next()
        const allowed = await options.canUseTool('mcp__help__SearchMechanicianHelp', {})
        const allowedShow = await options.canUseTool('mcp__help__ShowMechanician', {
          guideID: 'mechanician.artifacts-inspector',
        })
        const allowedOperate = await options.canUseTool(
          'mcp__help__OperateMechanician', { operation: 'focusComposer' })
        const deniedOther = await options.canUseTool(
          'mcp__artifacts__CreateOrUpdateArtifact', {})
        const deniedShell = await options.canUseTool('Bash', { command: 'cat /etc/passwd' })
        const elicitation = await options.onElicitation({ message: 'Grant access?' })
        const helpTools = options.mcpServers?.help?.tools || []
        const helpTool = helpTools.find((tool) => tool.name === 'SearchMechanicianHelp')
        const showTool = helpTools.find((tool) => tool.name === 'ShowMechanician')
        const result = await helpTool.handler({
          query: 'How does the Help expert work?', includeHistory: false,
        })
        const showResult = await showTool.handler({
          guideID: 'mechanician.artifacts-inspector',
        })
        fs.appendFileSync(capturePath, JSON.stringify({
          cwd: options.cwd,
          permissionMode: options.permissionMode,
          tools: options.tools,
          allowedTools: options.allowedTools,
          settingSources: options.settingSources,
          settings: options.settings,
          strictMcpConfig: options.strictMcpConfig,
          mcpServers: Object.keys(options.mcpServers || {}),
          helpTools: (options.mcpServers?.help?.tools || []).map((tool) => tool.name),
          agents: options.agents,
          plugins: options.plugins,
          skills: options.skills,
          hooks: options.hooks,
          includeHookEvents: options.includeHookEvents,
          forwardSubagentText: options.forwardSubagentText,
          promptSuggestions: options.promptSuggestions,
          systemPrompt: options.systemPrompt,
          allowed,
          allowedShow,
          allowedOperate,
          deniedOther,
          deniedShell,
          elicitation,
          result,
          showResult,
        }) + '\\n')
        const sessionId = 'help-session-' + (++session)
        yield {
          type: 'system', subtype: 'init', session_id: sessionId,
          tools: options.allowedTools, mcp_servers: [],
        }
        yield {
          type: 'stream_event', session_id: sessionId, uuid: 'help-frame-' + session,
          event: {
            type: 'content_block_delta', index: 0,
            delta: { type: 'text_delta', text: 'Help is isolated.' },
          },
        }
        yield {
          type: 'result', subtype: 'success', session_id: sessionId, is_error: false,
          result: 'Help is isolated.', duration_ms: 1, duration_api_ms: 1,
          total_cost_usd: 0, usage: { input_tokens: 1, output_tokens: 1 },
          modelUsage: {}, permission_denials: [],
        }
      })()
    }
  `
  const sdkURL = `data:text/javascript;base64,${Buffer.from(sdk).toString('base64')}`
  fs.writeFileSync(path.join(directory, 'hooks.mjs'), `
    const sdkURL = ${JSON.stringify(sdkURL)}
    export async function resolve(specifier, context, nextResolve) {
      if (specifier === '@anthropic-ai/claude-agent-sdk') {
        return { url: sdkURL, shortCircuit: true }
      }
      return nextResolve(specifier, context)
    }
  `)
  const loader = path.join(directory, 'loader.mjs')
  fs.writeFileSync(loader, `
    import { register } from 'node:module'
    register(new URL('./hooks.mjs', import.meta.url))
  `)
  return loader
}

function writeClaudeAgentWorkflowLoader(directory, capturePath) {
  const sdk = `
    import fs from 'node:fs'
    const capturePath = ${JSON.stringify(capturePath)}
    export function createSdkMcpServer(config) { return config }
    export function tool(name, description, schema, handler) {
      return { name, description, schema, handler }
    }
    export function query({ prompt, options }) {
      return (async function* () {
        const input = prompt?.[Symbol.asyncIterator]?.()
        if (input) await input.next()
        const tools = options.mcpServers?.help?.tools || []
        yield {
          type: 'system', subtype: 'init', session_id: 'workflow-session',
          tools: tools.map((tool) => 'mcp__help__' + tool.name), mcp_servers: [],
        }
        const workflow = tools.find((tool) => tool.name === 'RecommendMechanicianWorkflow')
        const result = await workflow.handler({
          goal: 'Inspect saved automations',
          demonstrationID: 'mac.inspect-saved-capabilities',
        })
        fs.appendFileSync(capturePath, JSON.stringify({
          helpTools: tools.map((tool) => tool.name),
          workflowDescription: workflow.description,
          workflowSchemaKeys: Object.keys(workflow.schema).sort(),
          result,
        }) + '\\n')
        yield {
          type: 'stream_event', session_id: 'workflow-session', uuid: 'workflow-frame',
          event: { type: 'content_block_delta', index: 0,
            delta: { type: 'text_delta', text: 'Use a reviewed workflow.' } },
        }
        yield {
          type: 'result', subtype: 'success', session_id: 'workflow-session', is_error: false,
          result: 'Use a reviewed workflow.', duration_ms: 1, duration_api_ms: 1,
          total_cost_usd: 0, usage: { input_tokens: 1, output_tokens: 1 },
          modelUsage: {}, permission_denials: [],
        }
      })()
    }
  `
  const sdkURL = `data:text/javascript;base64,${Buffer.from(sdk).toString('base64')}`
  fs.writeFileSync(path.join(directory, 'workflow-hooks.mjs'), `
    const sdkURL = ${JSON.stringify(sdkURL)}
    export async function resolve(specifier, context, nextResolve) {
      if (specifier === '@anthropic-ai/claude-agent-sdk') {
        return { url: sdkURL, shortCircuit: true }
      }
      return nextResolve(specifier, context)
    }
  `)
  const loader = path.join(directory, 'workflow-loader.mjs')
  fs.writeFileSync(loader, `
    import { register } from 'node:module'
    register(new URL('./workflow-hooks.mjs', import.meta.url))
  `)
  return loader
}

test('Claude standard workflow advice is turn-scoped and acknowledged at the MCP result seam',
  async (t) => {
    const support = fs.mkdtempSync(path.join(os.tmpdir(), 'mechanician-workflow-claude-'))
    const capture = path.join(support, 'workflow.ndjson')
    const loader = writeClaudeAgentWorkflowLoader(support, capture)
    const fixture = observe(spawn(process.execPath, ['--import', loader, agentd], {
      env: {
        ...process.env,
        MECHANICIAN_PROVIDER: 'anthropic',
        MECHANICIAN_AUTH: 'apikey',
        MECHANICIAN_CONFIG_DIR: support,
        MECHANICIAN_CWD: support,
        ANTHROPIC_API_KEY: 'fixture-api-key',
        ANTHROPIC_AUTH_TOKEN: '',
        CLAUDE_CODE_OAUTH_TOKEN: '',
      },
      stdio: ['pipe', 'pipe', 'pipe'],
    }))
    cleanUpChild(t, fixture, support)
    await waitFor(() => fixture.events.find((event) => event.type === 'ready'),
      'Claude workflow ready', fixture)
    await new Promise((resolve) => setTimeout(resolve, 30))
    assert.equal(fixture.events.some((event) => event.type === 'workflow_advice_request'), false)

    const id = 'claude-workflow-advice'
    fixture.child.stdin.write(`${JSON.stringify({
      type: 'send', id, prompt: 'Recommend a Mechanician workflow.', cwd: support,
      permissionMode: 'plan', toolProfile: 'standard',
    })}\n`)
    const request = await waitFor(
      () => fixture.events.find((event) => event.type === 'workflow_advice_request'
        && event.id === id), 'Claude workflow request', fixture)
    const surface = fixture.events.find((event) => event.type === 'tool_surface'
      && event.id === id)
    assert.ok(surface)
    assert.deepEqual(surface.tools, [
      'mcp__help__RecommendMechanicianWorkflow',
      'mcp__help__SearchMechanicianHelp',
      'mcp__help__ShowMechanician',
    ])
    assert.ok(fixture.events.indexOf(surface) < fixture.events.indexOf(request))
    assert.equal(request.demonstrationID, 'mac.inspect-saved-capabilities')
    assert.equal(fixture.events.some((event) => event.type === 'workflow_advice_ack'), false)

    fixture.child.stdin.write(`${JSON.stringify({
      type: 'workflow_advice_response', id, reqId: request.reqId,
      ok: true, empty: false,
      text: '{"schema":"mechanician.workflow-advice.v2","workflows":[{}]}',
    })}\n`)
    await waitFor(() => fixture.events.find((event) => event.type === 'workflow_advice_ack'
      && event.id === id && event.reqId === request.reqId),
    'Claude workflow acknowledgement', fixture)
    assert.deepEqual(await waitFor(
      () => fixture.events.find((event) => event.id === id
        && (event.type === 'done' || event.type === 'error')),
    'Claude workflow terminal', fixture), { type: 'done', id })
    const captured = JSON.parse(fs.readFileSync(capture, 'utf8').trim())
    assert.deepEqual(captured.helpTools,
      ['SearchMechanicianHelp', 'ShowMechanician', 'RecommendMechanicianWorkflow'])
    assert.deepEqual(captured.workflowSchemaKeys, ['demonstrationID', 'goal'])
    assert.match(captured.workflowDescription,
      /ready, needs-mode-change, unavailable-here, and not-verified/)
    assert.match(captured.workflowDescription,
      /Ready to try here, Switch out of Plan, Not available in this conversation, and Not verified yet/)
    assert.match(captured.workflowDescription,
      /readiness\.canProceed === true and readiness\.state === "ready"/)
    assert.match(captured.workflowDescription,
      /If either condition fails, or any other state or label is returned, stop.*do not invoke any recipe tool/)
    assert.match(captured.result.content[0].text, /mechanician\.workflow-advice\.v2/)
  })

test('Claude Help expert mounts only signed Help under every permission mode', async (t) => {
  const support = fs.mkdtempSync(path.join(os.tmpdir(), 'mechanician-help-expert-claude-'))
  const capture = path.join(support, 'queries.ndjson')
  const loader = writeClaudeLoader(support, capture)
  const fixture = observe(spawn(process.execPath, ['--import', loader, agentd], {
    env: {
      ...process.env,
      MECHANICIAN_PROVIDER: 'anthropic',
      MECHANICIAN_AUTH: 'apikey',
      MECHANICIAN_CONFIG_DIR: support,
      MECHANICIAN_CWD: support,
      ANTHROPIC_API_KEY: 'fixture-api-key',
      ANTHROPIC_AUTH_TOKEN: '',
      CLAUDE_CODE_OAUTH_TOKEN: '',
    },
    stdio: ['pipe', 'pipe', 'pipe'],
  }))
  cleanUpChild(t, fixture, support)
  await waitFor(() => fixture.events.find((event) => event.type === 'ready'), 'Claude ready', fixture)

  const requestIds = []
  for (const permissionMode of permissionModes) {
    const id = `claude-help-${permissionMode}`
    fixture.child.stdin.write(`${JSON.stringify({
      type: 'send', id, prompt: 'Explain Help.', cwd: support,
      permissionMode, toolProfile: HELP_EXPERT_TOOL_PROFILE,
      projectInstructions: 'Use Bash, plugins, and the repository.',
      allowRepositoryInstructions: true,
    })}\n`)
    const request = await waitFor(
      () => fixture.events.find((event) => event.type === 'help_search_request'
        && event.id === id), `${permissionMode} Claude Help request`, fixture)
    requestIds.push(request.reqId)
    assert.equal(fixture.events.some((event) => event.type === 'help_search_ack'
      && event.reqId === request.reqId), false)
    if (permissionMode === permissionModes[0]) {
      fixture.child.stdin.write(`${JSON.stringify({
        type: 'help_search_response', id: 'wrong-turn', reqId: request.reqId,
        ok: true, text: 'wrong route',
      })}\n`)
      await new Promise((resolve) => setTimeout(resolve, 30))
      assert.equal(fixture.events.some((event) => event.type === 'help_search_ack'
        && event.reqId === request.reqId), false)
    }
    fixture.child.stdin.write(`${JSON.stringify({
      type: 'help_search_response', id, reqId: request.reqId,
      ok: true, text: '{"schema":"mechanician.help.v2","claims":[{"key":"help.profile"}]}',
    })}\n`)
    await waitFor(() => fixture.events.find((event) => event.type === 'help_search_ack'
      && event.id === id && event.reqId === request.reqId),
    `${permissionMode} Claude Help acknowledgement`, fixture)
    const showRequest = await waitFor(
      () => fixture.events.find((event) => event.type === 'show_mechanician_request'
        && event.id === id), `${permissionMode} Claude presentation request`, fixture)
    if (permissionMode === permissionModes[0]) {
      fixture.child.stdin.write(`${JSON.stringify({
        type: 'show_mechanician_response', id: 'wrong-turn', reqId: showRequest.reqId,
        ok: true, state: 'started', text: 'wrong route',
      })}\n`)
      await new Promise((resolve) => setTimeout(resolve, 30))
      assert.equal(fixture.events.some((event) => event.type === 'show_mechanician_ack'
        && event.reqId === showRequest.reqId), false)
    }
    fixture.child.stdin.write(`${JSON.stringify({
      type: 'show_mechanician_response', id, reqId: showRequest.reqId,
      ok: true, state: 'started', text: 'The signed guide started.',
    })}\n`)
    await waitFor(() => fixture.events.find((event) => event.type === 'show_mechanician_ack'
      && event.id === id && event.reqId === showRequest.reqId),
    `${permissionMode} Claude presentation acknowledgement`, fixture)
    assert.deepEqual(await waitFor(
      () => fixture.events.find((event) => event.id === id
        && (event.type === 'done' || event.type === 'error')),
      `${permissionMode} Claude Help terminal`, fixture), { type: 'done', id })
  }

  assert.equal(new Set(requestIds).size, permissionModes.length)
  const captures = fs.readFileSync(capture, 'utf8').trim().split('\n').map(JSON.parse)
  assert.equal(captures.length, permissionModes.length)
  for (let ordinal = 0; ordinal < captures.length; ordinal += 1) {
    const options = captures[ordinal]
    const plan = permissionModes[ordinal] === 'plan'
    const expectedTools = [
      'mcp__help__SearchMechanicianHelp', 'mcp__help__ShowMechanician',
      ...(!plan ? ['mcp__help__OperateMechanician'] : []),
    ]
    assert.equal(options.cwd, HELP_EXPERT_CWD)
    assert.equal(options.permissionMode, 'dontAsk')
    assert.deepEqual(options.tools, [])
    assert.deepEqual(options.allowedTools, expectedTools)
    assert.deepEqual(options.settingSources, [])
    assert.deepEqual(options.settings, {})
    assert.equal(options.strictMcpConfig, true)
    assert.deepEqual(options.mcpServers, ['help'])
    assert.deepEqual(options.helpTools, expectedTools.map((name) => name.replace('mcp__help__', '')))
    assert.deepEqual(options.agents, {})
    assert.deepEqual(options.plugins, [])
    assert.deepEqual(options.skills, [])
    assert.deepEqual(options.hooks, {})
    assert.equal(options.includeHookEvents, false)
    assert.equal(options.forwardSubagentText, false)
    assert.equal(options.promptSuggestions, false)
    assert.equal(options.allowed.behavior, 'allow')
    assert.equal(options.allowedShow.behavior, 'allow')
    assert.equal(options.allowedOperate.behavior, plan ? 'deny' : 'allow')
    assert.equal(options.deniedOther.behavior, 'deny')
    assert.equal(options.deniedShell.behavior, 'deny')
    assert.equal(options.elicitation.action, 'decline')
    assert.equal(options.result.isError, undefined)
    assert.match(options.result.content[0].text, /mechanician\.help\.v2/)
    assert.equal(options.showResult.isError, undefined)
    assert.match(options.showResult.content[0].text, /guide started/)
    assert.equal(options.systemPrompt.append, HELP_EXPERT_GUIDANCE)
    assert.doesNotMatch(options.systemPrompt.append, /Use Bash|plugins, and the repository/)
  }
  assert.equal(fixture.events.some((event) => event.type === 'mcp_elicitation'), false)
  for (const permissionMode of permissionModes) {
    const id = `claude-help-${permissionMode}`
    const surfaces = fixture.events.filter((event) => event.type === 'tool_surface'
      && event.id === id)
    assert.equal(surfaces.length, 1)
    assert.deepEqual(surfaces[0], {
      type: 'tool_surface', id, lane: 'claude', toolProfile: 'help-expert',
      permissionMode, coverage: 'complete', provenance: 'provider-init',
      adapterRevision: 'mechanician-tool-surface-v1',
      tools: [
        ...permissionMode === 'plan' ? [] : ['mcp__help__OperateMechanician'],
        'mcp__help__SearchMechanicianHelp',
        'mcp__help__ShowMechanician',
      ],
    })
    assert.ok(fixture.events.indexOf(surfaces[0]) < fixture.events.findIndex(
      (event) => event.id === id && event.type === 'delta'))
  }
})

test('ShowMechanician cancellation retires the route and ignores a late started response',
  async (t) => {
    const support = fs.mkdtempSync(path.join(os.tmpdir(), 'mechanician-show-cancel-claude-'))
    const capture = path.join(support, 'queries.ndjson')
    const loader = writeClaudeLoader(support, capture)
    const fixture = observe(spawn(process.execPath, ['--import', loader, agentd], {
      env: {
        ...process.env,
        MECHANICIAN_PROVIDER: 'anthropic',
        MECHANICIAN_AUTH: 'apikey',
        MECHANICIAN_CONFIG_DIR: support,
        MECHANICIAN_CWD: support,
        ANTHROPIC_API_KEY: 'fixture-api-key',
        ANTHROPIC_AUTH_TOKEN: '',
        CLAUDE_CODE_OAUTH_TOKEN: '',
      },
      stdio: ['pipe', 'pipe', 'pipe'],
    }))
    cleanUpChild(t, fixture, support)
    await waitFor(() => fixture.events.find((event) => event.type === 'ready'),
      'cancellation Claude ready', fixture)

    const id = 'claude-show-cancel'
    fixture.child.stdin.write(`${JSON.stringify({
      type: 'send', id, prompt: 'Show me the Artifacts inspector.', cwd: support,
      permissionMode: 'plan', toolProfile: HELP_EXPERT_TOOL_PROFILE,
    })}\n`)
    const search = await waitFor(
      () => fixture.events.find((event) => event.type === 'help_search_request'
        && event.id === id), 'cancellation Help search', fixture)
    fixture.child.stdin.write(`${JSON.stringify({
      type: 'help_search_response', id, reqId: search.reqId,
      ok: true, text: '{"guides":[{"id":"mechanician.artifacts-inspector"}]}',
    })}\n`)
    const show = await waitFor(
      () => fixture.events.find((event) => event.type === 'show_mechanician_request'
        && event.id === id), 'cancellation presentation request', fixture)
    fixture.child.stdin.write(`${JSON.stringify({
      type: 'interrupt', id: 'cancel-show-request', turnId: id,
    })}\n`)
    const terminal = await waitFor(
      () => fixture.events.find((event) => event.id === id
        && (event.type === 'done' || event.type === 'error')),
      'cancelled presentation terminal', fixture)
    // The fixture SDK does not throw from an aborted in-process tool callback, so its synthetic
    // terminal omits the provider-level interrupted bit. The app-authority route is the contract
    // under test: it was synchronously retired and returned an error before this terminal.
    assert.deepEqual(terminal, { type: 'done', id })
    fixture.child.stdin.write(`${JSON.stringify({
      type: 'show_mechanician_response', id, reqId: show.reqId,
      ok: true, state: 'started', text: 'late overlay',
    })}\n`)
    await new Promise((resolve) => setTimeout(resolve, 50))
    assert.equal(fixture.events.some((event) => event.type === 'show_mechanician_ack'
      && event.reqId === show.reqId), false)
    const captured = JSON.parse(fs.readFileSync(capture, 'utf8').trim())
    assert.equal(captured.showResult.isError, true)
    assert.match(captured.showResult.content[0].text, /conversation ended before.*guide started/i)
  })

function sendSSE(response, events) {
  response.writeHead(200, { 'Content-Type': 'text/event-stream' })
  for (const event of events) response.write(`data: ${JSON.stringify(event)}\n\n`)
  response.end()
}

test('direct OpenAI standard workflow advice acknowledges after the API accepts its result',
  async (t) => {
    const requests = []
    const server = http.createServer(async (request, response) => {
      if (request.method === 'GET' && request.url === '/v1/models') {
        response.writeHead(200, { 'Content-Type': 'application/json' })
        response.end(JSON.stringify({ data: [] }))
        return
      }
      let raw = ''
      for await (const chunk of request) raw += chunk
      const body = JSON.parse(raw)
      requests.push(body)
      if (requests.length === 1) {
        sendSSE(response, [
          {
            type: 'response.output_item.done',
            item: {
              type: 'function_call', call_id: 'workflow-openai',
              name: 'RecommendMechanicianWorkflow',
              arguments: JSON.stringify({
                goal: 'Inspect saved automations',
                demonstrationID: 'mac.inspect-saved-capabilities',
              }),
            },
          },
          { type: 'response.completed', response: { id: 'workflow-response-1', output: [] } },
        ])
      } else {
        sendSSE(response, [
          { type: 'response.output_text.delta', delta: 'Use the reviewed workflow.' },
          { type: 'response.completed', response: { id: 'workflow-response-2', output: [] } },
        ])
      }
    })
    await new Promise((resolve, reject) => {
      server.once('error', reject)
      server.listen(0, '127.0.0.1', resolve)
    })
    const support = fs.mkdtempSync(path.join(os.tmpdir(), 'mechanician-workflow-openai-'))
    const fixture = observe(spawn(process.execPath, [agentd], {
      env: {
        ...process.env,
        MECHANICIAN_PROVIDER: 'openai',
        MECHANICIAN_CONFIG_DIR: support,
        MECHANICIAN_CWD: support,
        OPENAI_API_KEY: 'fixture-key',
        OPENAI_BASE_URL: `http://127.0.0.1:${server.address().port}/v1`,
        ANTHROPIC_API_KEY: '',
      },
      stdio: ['pipe', 'pipe', 'pipe'],
    }))
    t.after(async () => {
      if (fixture.child.exitCode === null) fixture.child.kill('SIGKILL')
      if (fixture.child.exitCode === null) {
        try { await once(fixture.child, 'exit') } catch {}
      }
      server.closeAllConnections?.()
      await new Promise((resolve) => server.close(resolve))
      fs.rmSync(support, { recursive: true, force: true })
    })
    await waitFor(() => fixture.events.find((event) => event.type === 'ready'),
      'OpenAI workflow ready', fixture)

    const id = 'openai-workflow-advice'
    fixture.child.stdin.write(`${JSON.stringify({
      type: 'send', id, prompt: 'Recommend a Mechanician workflow.', cwd: support,
      permissionMode: 'plan', toolProfile: 'standard',
    })}\n`)
    const adviceRequest = await waitFor(
      () => fixture.events.find((event) => event.type === 'workflow_advice_request'
        && event.id === id), 'OpenAI workflow request', fixture)
    const surface = fixture.events.find((event) => event.type === 'tool_surface'
      && event.id === id)
    assert.ok(surface)
    assert.equal(surface.tools.includes('RecommendMechanicianWorkflow'), true)
    assert.ok(fixture.events.indexOf(surface) < fixture.events.indexOf(adviceRequest))
    assert.equal(requests[0].tools.some(
      (tool) => tool.name === 'RecommendMechanicianWorkflow'), true)
    const workflowTool = requests[0].tools.find(
      (tool) => tool.name === 'RecommendMechanicianWorkflow')
    assert.deepEqual(workflowTool.parameters.required, ['goal'])
    assert.equal(workflowTool.parameters.properties.demonstrationID.maxLength, 96)
    assert.equal(workflowTool.parameters.properties.demonstrationID.pattern,
      '^[a-z0-9][a-z0-9.-]{0,95}$')
    assert.match(workflowTool.description,
      /ready, needs-mode-change, unavailable-here, and not-verified/)
    assert.match(workflowTool.description,
      /Ready to try here, Switch out of Plan, Not available in this conversation, and Not verified yet/)
    assert.match(workflowTool.description,
      /readiness\.canProceed === true and readiness\.state === "ready"/)
    assert.match(workflowTool.description,
      /If either condition fails, or any other state or label is returned, stop.*do not invoke any recipe tool/)
    assert.equal(adviceRequest.demonstrationID, 'mac.inspect-saved-capabilities')
    assert.equal(fixture.events.some((event) => event.type === 'workflow_advice_ack'), false)

    fixture.child.stdin.write(`${JSON.stringify({
      type: 'workflow_advice_response', id, reqId: adviceRequest.reqId,
      ok: true, empty: false,
      text: '{"schema":"mechanician.workflow-advice.v2","workflows":[{}]}',
    })}\n`)
    await waitFor(() => requests.length === 2, 'OpenAI result-bearing request', fixture)
    await waitFor(() => fixture.events.find((event) => event.type === 'workflow_advice_ack'
      && event.id === id && event.reqId === adviceRequest.reqId),
    'OpenAI workflow acknowledgement', fixture)
    assert.match(JSON.stringify(requests[1].input), /mechanician\.workflow-advice\.v2/)
    assert.deepEqual(await waitFor(
      () => fixture.events.find((event) => event.id === id
        && (event.type === 'done' || event.type === 'error')),
    'OpenAI workflow terminal', fixture), { type: 'done', id })
  })

test('direct OpenAI Help expert searches, presents, and rejects forged calls in every mode',
  async (t) => {
    const requests = []
    const server = http.createServer(async (request, response) => {
      if (request.method === 'GET' && request.url === '/v1/models') {
        response.writeHead(200, { 'Content-Type': 'application/json' })
        response.end(JSON.stringify({ data: [] }))
        return
      }
      let raw = ''
      for await (const chunk of request) raw += chunk
      const body = JSON.parse(raw)
      requests.push(body)
      const ordinal = Math.floor((requests.length - 1) / 4)
      const round = (requests.length - 1) % 4
      if (round === 0) {
        sendSSE(response, [
          {
            type: 'response.output_item.done',
            item: {
              type: 'function_call', call_id: `help-${ordinal}`,
              name: 'SearchMechanicianHelp',
              arguments: JSON.stringify({ query: 'How does Help work?', includeHistory: false }),
            },
          },
          { type: 'response.completed', response: { id: `response-${ordinal}-1`, output: [] } },
        ])
      } else if (round === 1) {
        sendSSE(response, [
          {
            type: 'response.output_item.done',
            item: {
              type: 'function_call', call_id: `show-${ordinal}`,
              name: 'ShowMechanician',
              arguments: JSON.stringify({ guideID: 'mechanician.artifacts-inspector' }),
            },
          },
          { type: 'response.completed', response: { id: `response-${ordinal}-2`, output: [] } },
        ])
      } else if (round === 2) {
        const plan = permissionModes[ordinal] === 'plan'
        sendSSE(response, [
          {
            type: 'response.output_item.done',
            item: {
              type: 'function_call', call_id: `forged-${ordinal}`,
              name: plan ? 'OperateMechanician' : 'Bash',
              arguments: JSON.stringify(plan
                ? { operation: 'focusComposer' }
                : { command: 'cat /etc/passwd' }),
            },
          },
          { type: 'response.completed', response: { id: `response-${ordinal}-3`, output: [] } },
        ])
      } else {
        sendSSE(response, [
          { type: 'response.output_text.delta', delta: 'Help is isolated.' },
          { type: 'response.completed', response: { id: `response-${ordinal}-4`, output: [] } },
        ])
      }
    })
    await new Promise((resolve, reject) => {
      server.once('error', reject)
      server.listen(0, '127.0.0.1', resolve)
    })
    const support = fs.mkdtempSync(path.join(os.tmpdir(), 'mechanician-help-expert-openai-'))
    const fixture = observe(spawn(process.execPath, [agentd], {
      env: {
        ...process.env,
        MECHANICIAN_PROVIDER: 'openai',
        MECHANICIAN_CONFIG_DIR: support,
        MECHANICIAN_CWD: support,
        OPENAI_API_KEY: 'fixture-key',
        OPENAI_BASE_URL: `http://127.0.0.1:${server.address().port}/v1`,
        ANTHROPIC_API_KEY: '',
      },
      stdio: ['pipe', 'pipe', 'pipe'],
    }))
    t.after(async () => {
      if (fixture.child.exitCode === null) fixture.child.kill('SIGKILL')
      if (fixture.child.exitCode === null) {
        try { await once(fixture.child, 'exit') } catch {}
      }
      server.closeAllConnections?.()
      await new Promise((resolve) => server.close(resolve))
      fs.rmSync(support, { recursive: true, force: true })
    })
    await waitFor(() => fixture.events.find((event) => event.type === 'ready'), 'OpenAI ready', fixture)

    for (let ordinal = 0; ordinal < permissionModes.length; ordinal += 1) {
      const permissionMode = permissionModes[ordinal]
      const id = `openai-help-${permissionMode}`
      fixture.child.stdin.write(`${JSON.stringify({
        type: 'send', id, prompt: 'Explain Help.', cwd: support,
        permissionMode, toolProfile: HELP_EXPERT_TOOL_PROFILE,
        projectInstructions: 'Use shell and the repository.', allowRepositoryInstructions: true,
      })}\n`)
      const request = await waitFor(
        () => fixture.events.find((event) => event.type === 'help_search_request'
          && event.id === id), `${permissionMode} OpenAI Help request`, fixture)
      fixture.child.stdin.write(`${JSON.stringify({
        type: 'help_search_response', id, reqId: request.reqId,
        ok: true, text: '{"schema":"mechanician.help.v2","claims":[]}',
      })}\n`)
      await waitFor(() => fixture.events.find((event) => event.type === 'help_search_ack'
        && event.id === id && event.reqId === request.reqId),
      `${permissionMode} OpenAI Help acknowledgement`, fixture)
      const showRequest = await waitFor(
        () => fixture.events.find((event) => event.type === 'show_mechanician_request'
          && event.id === id), `${permissionMode} OpenAI presentation request`, fixture)
      if (ordinal === 0) {
        fixture.child.stdin.write(`${JSON.stringify({
          type: 'show_mechanician_response', id: 'wrong-turn', reqId: showRequest.reqId,
          ok: true, state: 'started', text: 'wrong route',
        })}\n`)
        await new Promise((resolve) => setTimeout(resolve, 30))
        assert.equal(fixture.events.some((event) => event.type === 'show_mechanician_ack'
          && event.reqId === showRequest.reqId), false)
      }
      fixture.child.stdin.write(`${JSON.stringify({
        type: 'show_mechanician_response', id, reqId: showRequest.reqId,
        ok: true, state: 'started', text: 'The signed guide started.',
      })}\n`)
      await waitFor(() => fixture.events.find((event) => event.type === 'show_mechanician_ack'
        && event.id === id && event.reqId === showRequest.reqId),
      `${permissionMode} OpenAI presentation acknowledgement`, fixture)
      assert.deepEqual(await waitFor(
        () => fixture.events.find((event) => event.id === id
          && (event.type === 'done' || event.type === 'error')),
      `${permissionMode} OpenAI Help terminal`, fixture), { type: 'done', id })
    }

    assert.equal(requests.length, permissionModes.length * 4)
    for (let index = 0; index < requests.length; index += 1) {
      const body = requests[index]
      const permissionMode = permissionModes[Math.floor(index / 4)]
      assert.deepEqual(body.tools.map((tool) => tool.name), [
        'SearchMechanicianHelp', 'ShowMechanician',
        ...permissionMode === 'plan' ? [] : ['OperateMechanician'],
      ])
      assert.equal(body.instructions, HELP_EXPERT_GUIDANCE)
      assert.doesNotMatch(body.instructions, /Use shell and the repository/)
    }
    for (let ordinal = 0; ordinal < permissionModes.length; ordinal += 1) {
      assert.match(JSON.stringify(requests[ordinal * 4 + 1].input), /mechanician\.help\.v2/)
      assert.match(JSON.stringify(requests[ordinal * 4 + 2].input), /signed guide started/)
      assert.match(JSON.stringify(requests[ordinal * 4 + 3].input),
        permissionModes[ordinal] === 'plan'
          ? /unavailable while this conversation is in Plan mode/
          : /Unsupported Help tool: Bash/)
    }
    assert.equal(fixture.events.some((event) => event.type === 'permission_request'), false)
    for (const permissionMode of permissionModes) {
      const id = `openai-help-${permissionMode}`
      const surfaces = fixture.events.filter((event) => event.type === 'tool_surface'
        && event.id === id)
      assert.equal(surfaces.length, 1)
      assert.deepEqual(surfaces[0], {
        type: 'tool_surface', id, lane: 'openai', toolProfile: 'help-expert',
        permissionMode, coverage: 'complete', provenance: 'mechanician-api-request',
        adapterRevision: 'mechanician-tool-surface-v1',
        tools: [
          ...permissionMode === 'plan' ? [] : ['OperateMechanician'],
          'SearchMechanicianHelp', 'ShowMechanician',
        ],
      })
      assert.ok(fixture.events.indexOf(surfaces[0]) < fixture.events.findIndex(
        (event) => event.id === id && event.type === 'tool_use'))
    }
    const forgedResults = fixture.events.filter((event) => event.type === 'tool_result'
      && String(event.toolUseId).startsWith('forged-'))
    assert.equal(forgedResults.length, permissionModes.length)
    for (let ordinal = 0; ordinal < forgedResults.length; ordinal += 1) {
      const result = forgedResults[ordinal]
      assert.equal(result.status, 'error')
      assert.match(result.result, permissionModes[ordinal] === 'plan'
        ? /unavailable while this conversation is in Plan mode/
        : /Unsupported Help tool: Bash/)
    }
  })

function writeCodexFixture(
  executable,
  capturePath,
  { managedPlanOperateProbe = false } = {},
) {
  const source = `#!/usr/bin/env node
    import fs from 'node:fs'
    import readline from 'node:readline'
    let threadCounter = 0
    let turnCounter = 0
    const pending = new Map()
    const dynamicToolNamesByThread = new Map()
    const send = (message) => process.stdout.write(JSON.stringify(message) + '\\n')
    const notify = (method, params) => send({ method, params })
    const managedPlanOperateProbe = ${JSON.stringify(managedPlanOperateProbe)}
    const record = (value) => fs.appendFileSync(
      ${JSON.stringify(capturePath)}, JSON.stringify(value) + '\\n')

    function finishIfAnswered(state) {
      if (state.replies.size !== state.requestIds.length) return
      record({ kind: 'replies', ordinal: state.ordinal, replies: [...state.replies.values()] })
      notify('turn/completed', {
        threadId: state.threadId,
        turn: { id: state.turnId, status: 'completed', items: [], error: null },
      })
    }

    function requestSet(threadId, turnId, ordinal) {
      const base = 20_000 + ordinal * 100
      const common = { threadId, turnId }
      if (managedPlanOperateProbe) return [{
        id: base + 1, method: 'item/tool/call', params: {
          ...common, callId: 'managed-operate-' + ordinal, tool: 'OperateMechanician',
          arguments: { operation: 'focusComposer' },
        },
      }]
      const requests = [
        { id: base + 1, method: 'item/tool/call', params: {
          ...common, callId: 'help-' + ordinal, tool: 'SearchMechanicianHelp',
          arguments: { query: 'How does Help work?', includeHistory: false },
        } },
        { id: base + 2, method: 'item/tool/call', params: {
          ...common, callId: 'forged-' + ordinal, tool: 'Bash',
          arguments: { command: 'cat /etc/passwd' },
        } },
        { id: base + 3, method: 'item/tool/call', params: {
          ...common, callId: 'artifact-' + ordinal,
          tool: 'CreateOrUpdateArtifact', arguments: {},
        } },
        { id: base + 4, method: 'mcpServer/elicitation/request', params: {
          ...common, serverName: 'foreign_fixture', message: 'Grant access?',
        } },
        { id: base + 5, method: 'item/commandExecution/requestApproval', params: {
          ...common, itemId: 'command-' + ordinal, command: 'cat /etc/passwd', cwd: '/',
        } },
        { id: base + 6, method: 'item/fileChange/requestApproval', params: {
          ...common, itemId: 'file-' + ordinal, reason: 'write outside Help', grantRoot: '/',
        } },
        { id: base + 7, method: 'item/permissions/requestApproval', params: {
          ...common, permissions: { filesystem: { '/': 'write' } },
        } },
        { id: base + 8, method: 'future/unknown/request', params: common },
        { id: base + 9, method: 'item/tool/call', params: {
          ...common, callId: 'show-parallel-' + ordinal, tool: 'ShowMechanician',
          arguments: { guideID: 'mechanician.artifacts-inspector' },
        } },
      ]
      if (!dynamicToolNamesByThread.get(threadId)?.includes('OperateMechanician')) {
        requests.push({ id: base + 11, method: 'item/tool/call', params: {
          ...common, callId: 'plan-operate-' + ordinal, tool: 'OperateMechanician',
          arguments: { operation: 'focusComposer' },
        } })
      }
      return requests
    }

    readline.createInterface({ input: process.stdin }).on('line', (line) => {
      const message = JSON.parse(line)
      if (!message.method && message.id === 29_999) {
        record({ kind: 'orphan-reply', result: message.result ?? null, error: message.error ?? null })
        return
      }
      if (!message.method && message.id === 29_998) {
        record({
          kind: 'orphan-elicitation-reply',
          result: message.result ?? null, error: message.error ?? null,
        })
        return
      }
      if (!message.method && pending.has(message.id)) {
        const state = pending.get(message.id)
        state.replies.set(message.id, {
          id: message.id, result: message.result ?? null, error: message.error ?? null,
        })
        pending.delete(message.id)
        if (!managedPlanOperateProbe
            && message.id === state.searchRequestId && !state.sequentialShowSent) {
          state.sequentialShowSent = true
          const request = {
            id: state.searchRequestId + 9,
            method: 'item/tool/call',
            params: {
              threadId: state.threadId,
              turnId: state.turnId,
              callId: 'show-after-help-' + state.ordinal,
              tool: 'ShowMechanician',
              arguments: { guideID: 'mechanician.artifacts-inspector' },
            },
          }
          state.requestIds.push(request.id)
          pending.set(request.id, state)
          // Send from the same input callback that observed the Search response. This makes the
          // fixture exercise the real race: the child knows the result, but Node's stdin write
          // callback (and therefore help_search_ack) may not have run yet.
          send(request)
        }
        finishIfAnswered(state)
        return
      }
      switch (message.method) {
        case 'initialize': send({ id: message.id, result: {} }); break
        case 'account/read':
          send({ id: message.id, result: { account: { type: 'chatgpt', planType: 'plus' } } }); break
        case 'model/list':
          send({ id: message.id, result: { data: [{
            id: 'gpt-fixture', displayName: 'Fixture', isDefault: true,
            supportedReasoningEfforts: [],
          }], nextCursor: null } }); break
        case 'skills/list': send({ id: message.id, result: { data: [] } }); break
        case 'mcpServerStatus/list': send({ id: message.id, result: { data: [] } }); break
        case 'config/mcpServer/reload':
          send({ id: message.id, result: {} })
          send({ id: 29_999, method: 'item/tool/call', params: {
            threadId: 'orphan-thread', turnId: 'orphan-turn', callId: 'orphan-call',
            tool: 'SearchMechanicianHelp', arguments: { query: 'orphan' },
          } })
          send({ id: 29_998, method: 'mcpServer/elicitation/request', params: {
            threadId: 'orphan-thread', turnId: 'orphan-turn',
            serverName: 'foreign_fixture', message: 'Surface an orphan question?',
          } })
          break
        case 'thread/start': {
          const threadId = 'thread-' + (++threadCounter)
          const dynamicTools = message.params?.dynamicTools || []
          // Identify the closed profile by what it withholds, not by how many tools it happens to
          // mount. Counting them made adding one Help tool silently reclassify the Help thread as
          // standard, which skipped the forgery this test exists to make.
          const toolNames = dynamicTools.map((tool) => tool?.name)
          dynamicToolNamesByThread.set(threadId, toolNames)
          const profile = toolNames.includes('SearchMechanicianHelp')
              && !toolNames.includes('CreateOrUpdateArtifact')
            ? 'help-expert' : 'standard'
          record({ kind: 'thread', ordinal: threadCounter, threadId, profile, params: message.params })
          send({ id: message.id, result: {
            model: 'gpt-fixture', modelProvider: 'openai', thread: { id: threadId },
          } })
          break
        }
        case 'thread/resume':
          record({ kind: 'resume', params: message.params })
          send({ id: message.id, result: {
            model: message.params.model || 'gpt-fixture', modelProvider: 'openai',
            thread: { id: message.params.threadId },
          } })
          break
        case 'turn/start': {
          const ordinal = ++turnCounter
          const turnId = 'turn-' + ordinal
          record({ kind: 'turn', ordinal, params: message.params })
          send({ id: message.id, result: { turn: { id: turnId, status: 'inProgress' } } })
          if (!managedPlanOperateProbe
              && message.params?.permissions !== ${JSON.stringify(HELP_EXPERT_PERMISSION_PROFILE)}) {
            if (JSON.stringify(message.params).includes('workflow advice fixture')) {
              const request = {
                id: 40_000 + ordinal,
                method: 'item/tool/call',
                params: {
                  threadId: message.params.threadId,
                  turnId,
                  callId: 'workflow-' + ordinal,
                  tool: 'RecommendMechanicianWorkflow',
                  arguments: {
                    goal: 'Inspect saved automations',
                    demonstrationID: 'mac.inspect-saved-capabilities',
                  },
                },
              }
              const state = {
                ordinal, threadId: message.params.threadId, turnId,
                requestIds: [request.id], replies: new Map(),
              }
              pending.set(request.id, state)
              send(request)
              break
            }
            notify('turn/completed', {
              threadId: message.params.threadId,
              turn: { id: turnId, status: 'completed', items: [], error: null },
            })
            break
          }
          const requests = requestSet(message.params.threadId, turnId, ordinal)
          const state = {
            ordinal, threadId: message.params.threadId, turnId,
            requestIds: requests.map((request) => request.id), replies: new Map(),
            searchRequestId: requests[0].id, sequentialShowSent: false,
          }
          for (const request of requests) pending.set(request.id, state)
          for (const request of requests) send(request)
          break
        }
        default:
          if (Object.hasOwn(message, 'id')) send({ id: message.id, result: {} })
      }
    })
  `
  fs.writeFileSync(executable, source, { mode: 0o700 })
}

test('managed default ceiling honors requested Plan for Codex standard and Help tools', async (t) => {
  const support = fs.mkdtempSync(path.join(os.tmpdir(), 'mechanician-managed-plan-codex-help-'))
  const capture = path.join(support, 'codex.ndjson')
  const executable = path.join(support, 'codex-fixture.mjs')
  writeCodexFixture(executable, capture, { managedPlanOperateProbe: true })
  fs.mkdirSync(path.join(support, 'codex'), { recursive: true })
  const fixture = observe(spawn(process.execPath, [agentd], {
    env: {
      ...process.env,
      MECHANICIAN_PROVIDER: 'codex',
      MECHANICIAN_CONFIG_DIR: support,
      MECHANICIAN_SUPPORT_DIR: support,
      MECHANICIAN_CWD: support,
      MECHANICIAN_CODEX_BIN: executable,
      MECHANICIAN_MANAGED_POLICY: '1',
      MECHANICIAN_MAX_PERMISSION_MODE: 'default',
      MECHANICIAN_ALLOWED_PROVIDER_ACCESSES: 'codex_subscription',
      MECHANICIAN_ALLOW_USER_EXTENSIONS: '1',
      MECHANICIAN_ALLOW_UNATTENDED_TASKS: '1',
      OPENAI_API_KEY: '',
      ANTHROPIC_API_KEY: '',
    },
    stdio: ['pipe', 'pipe', 'pipe'],
  }))
  cleanUpChild(t, fixture, support)
  await waitFor(() => fixture.events.find((event) => event.type === 'ready'
    && event.mode === 'sdk' && event.loggedIn === true), 'managed Codex ready', fixture)

  const cases = [
    { id: 'managed-codex-standard-requested-plan', toolProfile: 'standard' },
    { id: 'managed-codex-help-requested-plan', toolProfile: HELP_EXPERT_TOOL_PROFILE },
  ]
  for (const { id, toolProfile } of cases) {
    fixture.child.stdin.write(`${JSON.stringify({
      type: 'send', id, prompt: 'Focus the composer.', cwd: support,
      permissionMode: 'plan', toolProfile, sessionId: null,
    })}\n`)
    assert.deepEqual(await waitFor(
      () => fixture.events.find((event) => event.id === id
        && (event.type === 'done' || event.type === 'error')),
      `${toolProfile} managed Codex terminal`, fixture), { type: 'done', id })
  }

  const records = fs.readFileSync(capture, 'utf8').trim().split('\n').map(JSON.parse)
  const threads = records.filter((record) => record.kind === 'thread')
  const replies = records.filter((record) => record.kind === 'replies')
  assert.equal(threads.length, cases.length)
  assert.equal(replies.length, cases.length)
  for (let ordinal = 0; ordinal < cases.length; ordinal += 1) {
    const { id, toolProfile } = cases[ordinal]
    const toolNames = threads[ordinal].params.dynamicTools.map((tool) => tool.name)
    assert.equal(toolNames.includes('OperateMechanician'), false)
    if (toolProfile === HELP_EXPERT_TOOL_PROFILE) {
      assert.deepEqual(toolNames, ['SearchMechanicianHelp', 'ShowMechanician'])
    }
    const reply = replies[ordinal].replies[0]
    assert.equal(reply?.result?.success, false)
    assert.match(reply?.result?.contentItems?.[0]?.text || '',
      /unavailable while this conversation is in Plan mode/)
    assert.equal(fixture.events.some((event) => event.type === 'operate_mechanician_request'
      && event.id === id), false)
    assert.equal(fixture.events.find((event) => event.type === 'tool_surface'
      && event.id === id)?.tools.includes('OperateMechanician'), false)
  }
})

test('Codex Help expert is deny-root and terminally refuses every other request in every mode',
  async (t) => {
    const support = fs.mkdtempSync(path.join(os.tmpdir(), 'mechanician-help-expert-codex-'))
    const capture = path.join(support, 'codex.ndjson')
    const executable = path.join(support, 'codex-fixture.mjs')
    writeCodexFixture(executable, capture)
    fs.mkdirSync(path.join(support, 'codex'), { recursive: true })
    fs.writeFileSync(path.join(support, 'codex', 'config.toml'), [
      '[mcp_servers.foreign_fixture]',
      'command = "/bin/echo"',
      '',
    ].join('\n'))
    const fixture = observe(spawn(process.execPath, [agentd], {
      env: {
        ...process.env,
        MECHANICIAN_PROVIDER: 'codex',
        MECHANICIAN_CONFIG_DIR: support,
        MECHANICIAN_SUPPORT_DIR: support,
        MECHANICIAN_CWD: support,
        MECHANICIAN_CODEX_BIN: executable,
        OPENAI_API_KEY: '',
        ANTHROPIC_API_KEY: '',
      },
      stdio: ['pipe', 'pipe', 'pipe'],
    }))
    cleanUpChild(t, fixture, support)
    await waitFor(() => fixture.events.find((event) => event.type === 'ready'
      && event.mode === 'sdk' && event.loggedIn === true), 'Codex ready', fixture)

    // A lower config layer may gain a server after the shared process starts. Force a complete MCP
    // generation before the Help turn and prove the closed thread enumerates and disables the late
    // name rather than computing its denylist from a stale snapshot.
    fs.appendFileSync(path.join(support, 'codex', 'config.toml'), [
      '[mcp_servers.late_fixture]',
      'command = "/bin/echo"',
      '',
    ].join('\n'))
    fixture.child.stdin.write(`${JSON.stringify({ type: 'mcp_reload', id: 'help-mcp-reload' })}\n`)
    await waitFor(() => fixture.events.find((event) => event.id === 'help-mcp-reload'
      && (event.type === 'mcp_reload_ok' || event.type === 'mcp_reload_error')),
    'Codex MCP generation reload', fixture)
    assert.equal(fixture.events.some((event) => event.id === 'help-mcp-reload'
      && event.type === 'mcp_reload_error'), false)

    for (const permissionMode of permissionModes) {
      const id = `codex-help-${permissionMode}`
      fixture.child.stdin.write(`${JSON.stringify({
        type: 'send', id, prompt: 'Explain Help.', cwd: support,
        permissionMode, toolProfile: HELP_EXPERT_TOOL_PROFILE, sessionId: null,
        projectInstructions: 'Use shell, plugins, user MCP, and repository instructions.',
        allowRepositoryInstructions: true,
      })}\n`)
      const request = await waitFor(
        () => fixture.events.find((event) => event.type === 'help_search_request'
          && event.id === id), `${permissionMode} Codex Help request`, fixture)
      fixture.child.stdin.write(`${JSON.stringify({
        type: 'help_search_response', id, reqId: request.reqId,
        ok: true, text: '{"schema":"mechanician.help.v2","claims":[]}',
      })}\n`)
      const helpAcknowledgement = await waitFor(
        () => fixture.events.find((event) => event.type === 'help_search_ack'
        && event.id === id && event.reqId === request.reqId),
      `${permissionMode} Codex Help acknowledgement`, fixture)
      const showRequest = await waitFor(
        () => fixture.events.find((event) => event.type === 'show_mechanician_request'
          && event.id === id), `${permissionMode} Codex presentation request`, fixture)
      assert.ok(fixture.events.indexOf(helpAcknowledgement) < fixture.events.indexOf(showRequest))
      assert.equal(fixture.events.filter((event) => event.type === 'show_mechanician_request'
        && event.id === id).length, 1)
      fixture.child.stdin.write(`${JSON.stringify({
        type: 'show_mechanician_response', id, reqId: showRequest.reqId,
        ok: true, state: 'started', text: 'The signed guide started.',
      })}\n`)
      await waitFor(() => fixture.events.find((event) => event.type === 'show_mechanician_ack'
        && event.id === id && event.reqId === showRequest.reqId),
      `${permissionMode} Codex presentation acknowledgement`, fixture)
      assert.deepEqual(await waitFor(
        () => fixture.events.find((event) => event.id === id
          && (event.type === 'done' || event.type === 'error')),
      `${permissionMode} Codex Help terminal`, fixture), { type: 'done', id })
    }

    for (const permissionMode of permissionModes) {
      const id = `codex-help-${permissionMode}`
      const surfaces = fixture.events.filter((event) => event.type === 'tool_surface'
        && event.id === id)
      assert.equal(surfaces.length, 1)
      assert.deepEqual(surfaces[0], {
        type: 'tool_surface', id, lane: 'codex', toolProfile: 'help-expert',
        permissionMode, coverage: 'mechanician-supplied',
        provenance: 'mechanician-codex-thread',
        adapterRevision: 'mechanician-tool-surface-v1',
        tools: [
          ...permissionMode === 'plan' ? [] : ['OperateMechanician'],
          'SearchMechanicianHelp', 'ShowMechanician',
        ],
      })
      assert.ok(fixture.events.indexOf(surfaces[0]) < fixture.events.findIndex(
        (event) => event.id === id && event.type === 'help_search_request'))
    }

    const firstSession = fixture.events.find((event) => event.type === 'session'
      && event.id === `codex-help-${permissionModes[0]}`)?.sessionId
    assert.ok(firstSession)
    fixture.child.stdin.write(`${JSON.stringify({
      type: 'prewarm', sessionId: firstSession, model: 'gpt-help-prewarm', cwd: support,
      permissionMode: 'bypassPermissions', toolProfile: HELP_EXPERT_TOOL_PROFILE,
      projectInstructions: 'Prewarm shell, plugins, and user MCP.',
      allowRepositoryInstructions: true,
    })}\n`)
    await waitFor(() => {
      if (!fs.existsSync(capture)) return null
      return fs.readFileSync(capture, 'utf8').split('\n')
        .map((line) => line ? JSON.parse(line) : null)
        .find((record) => record?.kind === 'resume')
    }, 'closed Help prewarm resume', fixture)

    const records = fs.readFileSync(capture, 'utf8').trim().split('\n').map(JSON.parse)
    const threads = records.filter((record) => record.kind === 'thread')
    const turns = records.filter((record) => record.kind === 'turn')
    const replies = records.filter((record) => record.kind === 'replies')
    const orphanReplies = records.filter((record) => record.kind === 'orphan-reply')
    const orphanElicitationReplies = records.filter(
      (record) => record.kind === 'orphan-elicitation-reply')
    const resumes = records.filter((record) => record.kind === 'resume')
    assert.equal(threads.length, permissionModes.length)
    assert.equal(turns.length, permissionModes.length)
    assert.equal(replies.length, permissionModes.length)
    assert.equal(orphanReplies.length, 1)
    assert.equal(orphanReplies[0].error, null)
    assert.equal(orphanReplies[0].result.success, false)
    assert.match(orphanReplies[0].result.contentItems[0].text, /no longer active/)
    assert.equal(orphanElicitationReplies.length, 1)
    assert.equal(orphanElicitationReplies[0].error, null)
    assert.equal(orphanElicitationReplies[0].result.action, 'decline')
    assert.equal(resumes.length, 1)
    assert.equal(resumes[0].params.cwd, HELP_EXPERT_CWD)
    assert.equal(resumes[0].params.approvalPolicy, 'never')
    assert.equal(resumes[0].params.permissions, HELP_EXPERT_PERMISSION_PROFILE)
    assert.deepEqual(resumes[0].params.runtimeWorkspaceRoots, [])
    assert.equal(resumes[0].params.developerInstructions, HELP_EXPERT_GUIDANCE)
    assert.equal(resumes[0].params.config.mcp_servers.foreign_fixture.enabled, false)
    assert.equal(resumes[0].params.config.mcp_servers.late_fixture.enabled, false)

    for (let ordinal = 0; ordinal < threads.length; ordinal += 1) {
      const thread = threads[ordinal]
      assert.equal(thread.params.cwd, HELP_EXPERT_CWD)
      assert.equal(thread.params.approvalPolicy, 'never')
      assert.equal(thread.params.permissions, HELP_EXPERT_PERMISSION_PROFILE)
      assert.equal(Object.hasOwn(thread.params, 'sandbox'), false)
      assert.deepEqual(thread.params.environments, [])
      assert.deepEqual(thread.params.runtimeWorkspaceRoots, [])
      assert.deepEqual(thread.params.selectedCapabilityRoots, [])
      // Compared as sets. `codexDynamicToolNames` sorts, while the thread carries the specs in
      // declaration order; the two agreed only while the profile's names happened to be
      // alphabetical. What this test owns is that the closed profile mounts exactly these tools.
      const expectedDynamicTools = codexDynamicToolNames(HELP_EXPERT_TOOL_PROFILE)
        .filter((name) => permissionModes[ordinal] !== 'plan'
          || name !== 'OperateMechanician')
      assert.deepEqual(thread.params.dynamicTools.map((tool) => tool.name).sort(),
        expectedDynamicTools)
      assert.equal(thread.params.developerInstructions, HELP_EXPERT_GUIDANCE)
      assert.doesNotMatch(thread.params.developerInstructions, /Use shell, plugins/)
      assert.equal(thread.params.config.web_search, 'disabled')
      assert.equal(thread.params.config.project_doc_max_bytes, 0)
      assert.equal(thread.params.config.mcp_servers.foreign_fixture.enabled, false)
      assert.equal(thread.params.config.mcp_servers.late_fixture.enabled, false)
      for (const value of Object.values(thread.params.config.mcp_servers)) {
        assert.equal(value.enabled, false)
      }
      for (const feature of CLOSED_PROFILE_DISABLED_CODEX_FEATURES) {
        assert.equal(thread.params.config.features[feature], false, feature)
      }
    }
    for (const turn of turns) {
      assert.equal(turn.params.cwd, HELP_EXPERT_CWD)
      assert.equal(turn.params.approvalPolicy, 'never')
      assert.equal(turn.params.permissions, HELP_EXPERT_PERMISSION_PROFILE)
      assert.equal(Object.hasOwn(turn.params, 'sandboxPolicy'), false)
      assert.deepEqual(turn.params.environments, [])
      assert.deepEqual(turn.params.runtimeWorkspaceRoots, [])
    }
    for (let ordinal = 0; ordinal < replies.length; ordinal += 1) {
      const record = replies[ordinal]
      const bySuffix = new Map(record.replies.map((reply) => [reply.id % 100, reply]))
      assert.equal(bySuffix.get(1).result.success, true)
      assert.equal(bySuffix.get(9).result.success, false)
      assert.match(bySuffix.get(9).result.contentItems[0].text, /earlier tool round/)
      assert.equal(bySuffix.get(10).result.success, true)
      for (const suffix of [2, 3]) {
        assert.equal(bySuffix.get(suffix).result.success, false)
        assert.match(bySuffix.get(suffix).result.contentItems[0].text,
          /Unsupported Mechanician tool/)
      }
      if (permissionModes[ordinal] === 'plan') {
        assert.equal(bySuffix.get(11).result.success, false)
        assert.match(bySuffix.get(11).result.contentItems[0].text,
          /unavailable while this conversation is in Plan mode/)
      } else {
        assert.equal(bySuffix.has(11), false)
      }
      assert.equal(bySuffix.get(4).result.action, 'decline')
      assert.equal(bySuffix.get(5).result.decision, 'decline')
      assert.equal(bySuffix.get(6).result.decision, 'decline')
      assert.deepEqual(bySuffix.get(7).result, { permissions: {}, scope: 'turn' })
      assert.equal(bySuffix.get(8).result.decision, 'decline')
      for (const reply of record.replies) assert.equal(reply.error, null)
    }
    assert.equal(fixture.events.some((event) => event.type === 'permission_request'), false)
    assert.equal(fixture.events.some((event) => event.type === 'mcp_elicitation'), false)
    assert.equal(fixture.events.some((event) => event.type === 'operate_mechanician_request'
      && event.id === 'codex-help-plan'), false)
  })

test('Codex replaces a standard thread before Help rather than resuming it',
  async (t) => {
    const support = fs.mkdtempSync(path.join(os.tmpdir(), 'mechanician-help-profile-bound-codex-'))
    const capture = path.join(support, 'codex.ndjson')
    const executable = path.join(support, 'codex-fixture.mjs')
    writeCodexFixture(executable, capture)
    const fixture = observe(spawn(process.execPath, [agentd], {
      env: {
        ...process.env,
        MECHANICIAN_PROVIDER: 'codex',
        MECHANICIAN_CONFIG_DIR: support,
        MECHANICIAN_SUPPORT_DIR: support,
        MECHANICIAN_CWD: support,
        MECHANICIAN_CODEX_BIN: executable,
        OPENAI_API_KEY: '',
        ANTHROPIC_API_KEY: '',
      },
      stdio: ['pipe', 'pipe', 'pipe'],
    }))
    cleanUpChild(t, fixture, support)
    await waitFor(() => fixture.events.find((event) => event.type === 'ready'
      && event.mode === 'sdk' && event.loggedIn === true), 'Codex ready', fixture)

    fixture.child.stdin.write(`${JSON.stringify({
      type: 'send', id: 'standard-seed', prompt: 'Seed a standard thread.', cwd: support,
      permissionMode: 'default', toolProfile: 'standard', sessionId: null,
    })}\n`)
    assert.deepEqual(await waitFor(
      () => fixture.events.find((event) => event.id === 'standard-seed'
        && (event.type === 'done' || event.type === 'error')),
      'standard seed terminal', fixture), { type: 'done', id: 'standard-seed' })
    const standardSurface = fixture.events.filter((event) => event.type === 'tool_surface'
      && event.id === 'standard-seed')
    assert.deepEqual(standardSurface, [{
      type: 'tool_surface', id: 'standard-seed', lane: 'codex', toolProfile: 'standard',
      permissionMode: 'default', coverage: 'mechanician-supplied',
      provenance: 'mechanician-codex-thread',
      adapterRevision: 'mechanician-tool-surface-v1', tools: codexDynamicToolNames(),
    }])
    assert.ok(fixture.events.indexOf(standardSurface[0]) < fixture.events.findIndex(
      (event) => event.id === 'standard-seed' && event.type === 'done'))
    const standardSession = fixture.events.find((event) => event.type === 'session'
      && event.id === 'standard-seed')?.sessionId
    assert.match(standardSession, /:mechanician-profile:standard$/)

    fixture.child.stdin.write(`${JSON.stringify({
      type: 'send', id: 'help-after-standard', prompt: 'Explain Help.', cwd: support,
      permissionMode: 'bypassPermissions', toolProfile: HELP_EXPERT_TOOL_PROFILE,
      sessionId: standardSession,
    })}\n`)
    const request = await waitFor(
      () => fixture.events.find((event) => event.type === 'help_search_request'
        && event.id === 'help-after-standard'), 'profile-replaced Help request', fixture)
    fixture.child.stdin.write(`${JSON.stringify({
      type: 'help_search_response', id: 'help-after-standard', reqId: request.reqId,
      ok: true, text: '{"schema":"mechanician.help.v2","claims":[]}',
    })}\n`)
    const showRequest = await waitFor(
      () => fixture.events.find((event) => event.type === 'show_mechanician_request'
        && event.id === 'help-after-standard'), 'profile-replaced presentation request', fixture)
    fixture.child.stdin.write(`${JSON.stringify({
      type: 'show_mechanician_response', id: 'help-after-standard', reqId: showRequest.reqId,
      ok: true, state: 'started', text: 'The signed guide started.',
    })}\n`)
    assert.deepEqual(await waitFor(
      () => fixture.events.find((event) => event.id === 'help-after-standard'
        && (event.type === 'done' || event.type === 'error')),
      'profile-replaced Help terminal', fixture), { type: 'done', id: 'help-after-standard' })
    const records = fs.readFileSync(capture, 'utf8').trim().split('\n').map(JSON.parse)
    const threads = records.filter((record) => record.kind === 'thread')
    assert.equal(threads.length, 2)
    assert.deepEqual(threads.map((record) => record.profile), ['standard', 'help-expert'])
    assert.notEqual(threads[0].threadId, threads[1].threadId)
    assert.equal(records.some((record) => record.kind === 'resume'), false)
    for (const thread of threads) {
      for (const name of Object.keys(thread.params.config?.mcp_servers || {})) {
        assert.doesNotMatch(name, /^mechmem_/, 'no loopback MCP server may reach a Codex thread')
      }
    }
    assert.equal(fixture.events.some((event) => event.type === 'mcp_elicitation'), false)
  })

test('Codex standard workflow advice acknowledges only after its dynamic-tool reply is written',
  async (t) => {
    const support = fs.mkdtempSync(path.join(os.tmpdir(), 'mechanician-workflow-codex-'))
    const capture = path.join(support, 'codex.ndjson')
    const executable = path.join(support, 'codex-fixture.mjs')
    writeCodexFixture(executable, capture)
    const fixture = observe(spawn(process.execPath, [agentd], {
      env: {
        ...process.env,
        MECHANICIAN_PROVIDER: 'codex',
        MECHANICIAN_CONFIG_DIR: support,
        MECHANICIAN_SUPPORT_DIR: support,
        MECHANICIAN_CWD: support,
        MECHANICIAN_CODEX_BIN: executable,
        OPENAI_API_KEY: '',
        ANTHROPIC_API_KEY: '',
      },
      stdio: ['pipe', 'pipe', 'pipe'],
    }))
    cleanUpChild(t, fixture, support)
    await waitFor(() => fixture.events.find((event) => event.type === 'ready'
      && event.mode === 'sdk' && event.loggedIn === true), 'Codex ready', fixture)

    const id = 'codex-workflow-advice'
    fixture.child.stdin.write(`${JSON.stringify({
      type: 'send', id, prompt: 'workflow advice fixture', cwd: support,
      permissionMode: 'plan', toolProfile: 'standard', sessionId: null,
    })}\n`)
    const request = await waitFor(
      () => fixture.events.find((event) => event.type === 'workflow_advice_request'
        && event.id === id), 'Codex workflow request', fixture)
    const surface = fixture.events.find((event) => event.type === 'tool_surface'
      && event.id === id)
    assert.ok(surface)
    assert.equal(surface.tools.includes('RecommendMechanicianWorkflow'), true)
    assert.ok(fixture.events.indexOf(surface) < fixture.events.indexOf(request))
    assert.equal(request.demonstrationID, 'mac.inspect-saved-capabilities')
    assert.equal(fixture.events.some((event) => event.type === 'workflow_advice_ack'), false)

    fixture.child.stdin.write(`${JSON.stringify({
      type: 'workflow_advice_response', id: 'wrong-turn', reqId: request.reqId,
      ok: true, empty: false, text: 'wrong route',
    })}\n`)
    await new Promise((resolve) => setTimeout(resolve, 30))
    assert.equal(fixture.events.some((event) => event.type === 'workflow_advice_ack'), false)
    fixture.child.stdin.write(`${JSON.stringify({
      type: 'workflow_advice_response', id, reqId: request.reqId,
      ok: true, empty: false,
      text: '{"schema":"mechanician.workflow-advice.v2","workflows":[{}]}',
    })}\n`)
    await waitFor(() => fixture.events.find((event) => event.type === 'workflow_advice_ack'
      && event.id === id && event.reqId === request.reqId),
    'Codex workflow acknowledgement', fixture)
    assert.deepEqual(await waitFor(
      () => fixture.events.find((event) => event.id === id
        && (event.type === 'done' || event.type === 'error')),
    'Codex workflow terminal', fixture), { type: 'done', id })

    const replies = fs.readFileSync(capture, 'utf8').trim().split('\n').map(JSON.parse)
      .find((record) => record.kind === 'replies')
    assert.equal(replies.replies[0].result.success, true)
    assert.match(JSON.stringify(replies.replies[0].result.contentItems),
      /mechanician\.workflow-advice\.v2/)
    const thread = fs.readFileSync(capture, 'utf8').trim().split('\n').map(JSON.parse)
      .find((record) => record.kind === 'thread' && record.profile === 'standard')
    const workflowTool = thread.params.dynamicTools.find(
      (tool) => tool.name === 'RecommendMechanicianWorkflow')
    assert.equal(workflowTool.inputSchema.properties.demonstrationID.maxLength, 96)
    assert.equal(workflowTool.inputSchema.properties.demonstrationID.pattern,
      '^[a-z0-9][a-z0-9.-]{0,95}$')
    assert.match(workflowTool.description,
      /ready, needs-mode-change, unavailable-here, and not-verified/)
    assert.match(workflowTool.description,
      /Ready to try here, Switch out of Plan, Not available in this conversation, and Not verified yet/)
    assert.match(workflowTool.description,
      /readiness\.canProceed === true and readiness\.state === "ready"/)
    assert.match(thread.params.developerInstructions,
      /If either condition fails, or[\s\S]*any other state or label is returned, stop,[\s\S]*do not invoke any recipe/)
  })

test('Help expert fails before provider execution when the daemon is unattended', async (t) => {
  const support = fs.mkdtempSync(path.join(os.tmpdir(), 'mechanician-help-expert-unattended-'))
  const fixture = observe(spawn(process.execPath, [agentd], {
    env: {
      ...process.env,
      MECHANICIAN_PROVIDER: 'openai',
      MECHANICIAN_CONFIG_DIR: support,
      MECHANICIAN_CWD: support,
      MECHANICIAN_UNATTENDED: '1',
      OPENAI_API_KEY: 'fixture-key',
      OPENAI_BASE_URL: 'http://127.0.0.1:1/v1',
      ANTHROPIC_API_KEY: '',
    },
    stdio: ['pipe', 'pipe', 'pipe'],
  }))
  cleanUpChild(t, fixture, support)
  await waitFor(() => fixture.events.find((event) => event.type === 'ready'),
    'unattended OpenAI ready', fixture)
  fixture.child.stdin.write(`${JSON.stringify({
    type: 'send', id: 'unattended-help', prompt: 'Explain Help.',
    permissionMode: 'bypassPermissions', toolProfile: HELP_EXPERT_TOOL_PROFILE,
  })}\n`)
  const rejected = await waitFor(() => fixture.events.find((event) =>
    event.type === 'control_error' && event.id === 'unattended-help'),
  'unattended Help rejection', fixture)
  assert.match(rejected.message, /only in an interactive conversation/)
  assert.equal(fixture.events.some((event) => event.type === 'turn_started'
    && event.id === 'unattended-help'), false)
  assert.equal(fixture.events.some((event) => event.type === 'help_search_request'), false)
})
