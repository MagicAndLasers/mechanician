// WHERE CONTAINMENT ACTUALLY RUNS, not whether the policy function is correct.
//
// `write-containment.test.mjs` covers the policy. This file covers the wiring, because the wiring
// is where it failed: both the credential boundary and the write-escape gate lived only in
// `canUseTool`, and the pinned SDK does not invoke `canUseTool` under `bypassPermissions`. Full
// access is the mode long multi-agent sessions run in, so two checks documented as unconditional
// ran in no Full-access turn at all. A policy unit test cannot see that. This drives the daemon
// with a stub SDK that calls the registered PreToolUse hooks the way the engine does.
import assert from 'node:assert/strict'
import { once } from 'node:events'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { spawn } from 'node:child_process'
import { fileURLToPath } from 'node:url'
import { test } from 'node:test'

const here = path.dirname(fileURLToPath(import.meta.url))
const agentd = path.resolve(here, '../src/agentd.mjs')

async function waitFor(predicate, description, fixture, timeout = 15_000) {
  const deadline = Date.now() + timeout
  while (Date.now() < deadline) {
    const value = predicate()
    if (value) return value
    await new Promise((resolve) => setTimeout(resolve, 10))
  }
  assert.fail(`timed out waiting for ${description}\nagentd stderr:\n${fixture.stderr}`
    + `\nrecent events:\n${JSON.stringify(fixture.events.slice(-20), null, 2)}`)
}

function observe(child) {
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
  return { child, events, get stderr() { return stderr } }
}

function cleanUp(t, fixture, directory) {
  t.after(async () => {
    if (fixture.child.exitCode === null) fixture.child.kill('SIGKILL')
    if (fixture.child.exitCode === null) {
      try { await once(fixture.child, 'exit') } catch {}
    }
    fs.rmSync(directory, { recursive: true, force: true, maxRetries: 20, retryDelay: 10 })
  })
}

/// A stub SDK that runs every registered PreToolUse hook, in order, short-circuiting on a deny.
/// It deliberately never calls `canUseTool`, which is exactly what the real SDK does in
/// `bypassPermissions` and is the condition this whole file exists to pin.
function writeLoader(directory, capturePath, calls) {
  const sdk = `
    import fs from 'node:fs'
    const capturePath = ${JSON.stringify(capturePath)}
    const calls = ${JSON.stringify(calls)}
    let turnOrdinal = 0

    export function createSdkMcpServer(config) { return config }
    export function tool(name, description, schema, handler) {
      return { name, description, schema, handler }
    }
    export function query({ prompt, options }) {
      const hooks = options?.hooks?.PreToolUse?.[0]?.hooks ?? []
      const ordinal = ++turnOrdinal
      const stream = (async function* () {
        const input = prompt?.[Symbol.asyncIterator]?.()
        if (input) await input.next()
        const call = calls[ordinal - 1]
        let outcome = {}
        if (call) {
          for (const hook of hooks) {
            const result = await hook({ tool_name: call.tool, tool_input: call.input })
            if (result && Object.keys(result).length) {
              outcome = result
              if (result.hookSpecificOutput?.permissionDecision === 'deny') break
            }
          }
        }
        fs.appendFileSync(capturePath, JSON.stringify({ ordinal, outcome }) + '\\n')
        yield {
          type: 'system', subtype: 'init', session_id: 'fixture-session-' + ordinal,
          tools: [], mcp_servers: [],
        }
        // Without a content frame the daemon reports provider_no_output and refuses the turn,
        // which times out every wait in this file for a reason that has nothing to do with hooks.
        yield {
          type: 'stream_event', session_id: 'fixture-session-' + ordinal,
          uuid: 'fixture-frame-' + ordinal,
          event: {
            type: 'content_block_delta', index: 0,
            delta: { type: 'text_delta', text: 'finished' },
          },
        }
        yield {
          type: 'result', subtype: 'success', session_id: 'fixture-session-' + ordinal,
          is_error: false, result: 'finished', duration_ms: 1, duration_api_ms: 1,
          total_cost_usd: 0, usage: { input_tokens: 1, output_tokens: 1 },
          modelUsage: {}, permission_denials: [], uuid: 'fixture-result-' + ordinal,
        }
      })()
      stream.supportedCommands = async () => []
      return stream
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

function startDaemon(t, buildCalls) {
  const support = fs.realpathSync(
    fs.mkdtempSync(path.join(os.tmpdir(), 'mechanician-containment-runtime-')))
  const workspace = path.join(support, 'workspace')
  fs.mkdirSync(workspace, { recursive: true })
  const capture = path.join(support, 'hook-results.ndjson')
  const loader = writeLoader(support, capture, buildCalls(workspace))
  const fixture = observe(spawn(process.execPath, ['--import', loader, agentd], {
    env: {
      ...process.env,
      MECHANICIAN_PROVIDER: 'anthropic',
      MECHANICIAN_AUTH: 'apikey',
      MECHANICIAN_CONFIG_DIR: support,
      MECHANICIAN_SUPPORT_DIR: support,
      MECHANICIAN_CWD: workspace,
      ANTHROPIC_API_KEY: 'fixture-api-key',
      ANTHROPIC_AUTH_TOKEN: '',
      CLAUDE_CODE_OAUTH_TOKEN: '',
    },
    stdio: ['pipe', 'pipe', 'pipe'],
  }))
  cleanUp(t, fixture, support)
  return { fixture, support, workspace, capture }
}

function captured(capturePath) {
  if (!fs.existsSync(capturePath)) return []
  return fs.readFileSync(capturePath, 'utf8').split('\n').filter(Boolean).map((l) => JSON.parse(l))
}

test('a write escaping the workspace is gated in Full access', async (t) => {
  // NOT under os.tmpdir(): the guard always allows the real temp directory, and the whole fixture
  // lives there, so a temp-rooted target is contained by design and would pass for the wrong
  // reason. Nothing is ever created here; the hook refuses before any write is performed.
  const outside = path.join(os.homedir(), 'mechanician-containment-fixture', 'Stolen.swift')
  const { fixture, workspace, capture } = startDaemon(t, () => [
    { tool: 'Write', input: { file_path: outside, content: 'x' } },
  ])
  await waitFor(() => fixture.events.find((e) => e.type === 'ready'), 'ready', fixture)
  fixture.child.stdin.write(`${JSON.stringify({
    type: 'send', id: 'escape-turn', convId: 'escape-turn', prompt: 'Write it.',
    cwd: workspace, permissionMode: 'bypassPermissions',
  })}\n`)

  // The gate asks rather than refusing outright: Full access means "do not prompt me about my
  // workspace", not "write anywhere on this disk". The prompt is the whole point of the fix.
  const request = await waitFor(
    () => fixture.events.find((e) => e.type === 'permission_request' && e.id === 'escape-turn'),
    'write-escape approval in bypassPermissions', fixture)
  assert.equal(request.name, 'Write')
  assert.equal(request.writeEscape.workspace, workspace)

  fixture.child.stdin.write(`${JSON.stringify({
    type: 'permission_response', id: 'reply-1', permissionId: request.permissionId, allow: false,
  })}\n`)
  await waitFor(() => captured(capture).length >= 1, 'hook outcome recorded', fixture)
  const [first] = captured(capture)
  assert.equal(first.outcome.hookSpecificOutput?.hookEventName, 'PreToolUse')
  assert.equal(first.outcome.hookSpecificOutput?.permissionDecision, 'deny')
})

test('a credential-store read is refused in Full access without a prompt', async (t) => {
  const { fixture, workspace, capture } = startDaemon(t, () => [
    { tool: 'Read', input: { file_path: path.join(os.homedir(), '.aws', 'credentials') } },
  ])
  await waitFor(() => fixture.events.find((e) => e.type === 'ready'), 'ready', fixture)
  fixture.child.stdin.write(`${JSON.stringify({
    type: 'send', id: 'credential-turn', convId: 'credential-turn', prompt: 'Read it.',
    cwd: workspace, permissionMode: 'bypassPermissions',
  })}\n`)

  await waitFor(() => captured(capture).length >= 1, 'hook outcome recorded', fixture)
  const [first] = captured(capture)
  assert.equal(first.outcome.hookSpecificOutput?.permissionDecision, 'deny')
  assert.match(first.outcome.hookSpecificOutput.permissionDecisionReason, /credential|secret|token/i)
  // The refusal is disclosed, not silent. FR-224 was a wrong pattern nobody could see.
  assert.ok(fixture.events.some((e) => e.type === 'subtraction' && e.id === 'credential-turn'))
  // And it never becomes an approval prompt: a data boundary is not a preference.
  assert.ok(!fixture.events.some((e) => e.type === 'permission_request'))
})

test('a contained write in Full access is left alone', async (t) => {
  const { fixture, workspace, capture } = startDaemon(t, (root) => [
    { tool: 'Write', input: { file_path: path.join(root, 'Inside.swift'), content: 'x' } },
  ])
  await waitFor(() => fixture.events.find((e) => e.type === 'ready'), 'ready', fixture)
  fixture.child.stdin.write(`${JSON.stringify({
    type: 'send', id: 'contained-turn', convId: 'contained-turn', prompt: 'Write it.',
    cwd: workspace, permissionMode: 'bypassPermissions',
  })}\n`)
  await waitFor(() => captured(capture).length >= 1, 'hook outcome recorded', fixture)
  const [first] = captured(capture)
  // No opinion. Full access proceeds exactly as it did before, which is the point: the gate must
  // cost nothing on the overwhelming majority of calls.
  assert.deepEqual(first.outcome, {})
  assert.ok(!fixture.events.some((e) => e.type === 'permission_request'))
})
