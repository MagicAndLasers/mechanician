// Stop must end a turn that has not reached the provider yet.
//
// Reported on 0.26.6 from a managed Vertex deployment: the Stop button "doesn't appear to be
// working". The cause is a sequencing gap, not the button. `runSdk` registers the turn in
// `activeTurns` before it prepares the query, but Stop is wired to `ctx.abortController`, which does
// not exist until preparation finishes. An interrupt arriving in between set `ctx.interrupted`,
// found nothing to abort, and the turn ran to completion and answered.
//
// The window is invisible on an API-key lane, where `preflightAnthropicTurn` returns immediately.
// On Vertex it contains a live ADC token refresh, which is why this reproduced on the managed
// enterprise build and never in local dogfooding. This test holds the refresh open, interrupts
// inside it, and proves the provider is never asked to run the turn.

import assert from 'node:assert/strict'
import { once } from 'node:events'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { spawn } from 'node:child_process'
import { fileURLToPath, pathToFileURL } from 'node:url'
import { test } from 'node:test'

const here = path.dirname(fileURLToPath(import.meta.url))
const agentd = path.resolve(here, '../src/agentd.mjs')
// A `data:` module has no filesystem base, so the stub must name the real module by file URL.
const realVertexAdc = pathToFileURL(path.resolve(here, '../src/vertex-adc.mjs')).href

async function waitFor(predicate, description, fixture, timeout = 10_000) {
  const deadline = Date.now() + timeout
  while (Date.now() < deadline) {
    const value = predicate()
    if (value) return value
    await new Promise((resolve) => setTimeout(resolve, 10))
  }
  assert.fail(`timed out waiting for ${description}\nagentd stderr:\n${fixture.stderr}`)
}

/// Redirect the Agent SDK and the Vertex ADC module. The ADC stub holds `refreshTokens` open until
/// `releaseFile` appears, which is the whole point: it makes the pre-preparation window
/// deterministic instead of a race against a real network call.
function writeLoader(directory, { captureFile, releaseFile }) {
  const sdkSource = `
    import fs from 'node:fs'
    const capture = ${JSON.stringify(captureFile)}
    const record = (event) => fs.appendFileSync(capture, event + '\\n')

    export function createSdkMcpServer(config) { return config }
    export function tool(name, description, schema, handler) {
      return { name, description, schema, handler }
    }

    function providerQuery() {
      // Reaching here at all is the regression: the user pressed Stop before the turn was prepared.
      record('provider-query')
      const stream = (async function* () {
        yield { type: 'assistant', message: { content: [{ type: 'text', text: 'answered anyway' }] } }
        yield {
          type: 'result', subtype: 'success', session_id: 'fixture-session',
          is_error: false, result: 'answered anyway', duration_ms: 1, num_turns: 1,
          total_cost_usd: 0,
          usage: {
            input_tokens: 1, output_tokens: 1,
            cache_creation_input_tokens: 0, cache_read_input_tokens: 0,
          },
          modelUsage: {}, permission_denials: [], uuid: 'fixture-result',
        }
      })()
      stream.supportedCommands = async () => []
      stream.interrupt = async () => { record('stream-interrupt') }
      return stream
    }

    export function query() { return providerQuery() }
    export async function startup() {
      return { query: () => providerQuery(), close() {} }
    }
  `
  const adcSource = `
    import fs from 'node:fs'
    export { resolveVertexAuthState } from ${JSON.stringify(realVertexAdc)}
    const capture = ${JSON.stringify(captureFile)}
    const release = ${JSON.stringify(releaseFile)}
    const record = (event) => fs.appendFileSync(capture, event + '\\n')

    export function createVertexAdc() {
      return {
        hasCredentials: () => true,
        checkAuth: async () => ({ ok: true }),
        getIdentityToken: async () => null,
        async refreshTokens() {
          record('preflight-entered')
          // Hold the turn exactly where Stop used to be ignored.
          while (!fs.existsSync(release)) {
            await new Promise((resolve) => setTimeout(resolve, 10))
          }
          record('preflight-released')
          return { ok: true }
        },
      }
    }
  `
  const sdkURL = `data:text/javascript;base64,${Buffer.from(sdkSource).toString('base64')}`
  const adcURL = `data:text/javascript;base64,${Buffer.from(adcSource).toString('base64')}`
  fs.writeFileSync(path.join(directory, 'hooks.mjs'), `
    const sdkURL = ${JSON.stringify(sdkURL)}
    const adcURL = ${JSON.stringify(adcURL)}
    export async function resolve(specifier, context, nextResolve) {
      if (specifier === '@anthropic-ai/claude-agent-sdk') {
        return { url: sdkURL, shortCircuit: true }
      }
      // Exactly the relative specifier agentd uses. The stub itself imports the real module by
      // absolute path, so this must not match on a suffix or that import would recurse.
      if (specifier === './vertex-adc.mjs') {
        return { url: adcURL, shortCircuit: true }
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

test('Stop ends a Vertex turn interrupted while its credential preflight is still running', async (t) => {
  const support = fs.mkdtempSync(path.join(os.tmpdir(), 'mechanician-stop-preflight-'))
  const capture = path.join(support, 'sdk-events.txt')
  const release = path.join(support, 'release-preflight')
  const loader = writeLoader(support, { captureFile: capture, releaseFile: release })
  const child = spawn(process.execPath, ['--import', loader, agentd], {
    env: {
      ...process.env,
      MECHANICIAN_PROVIDER: 'anthropic',
      MECHANICIAN_AUTH: 'vertex',
      MECHANICIAN_VERTEX_PROJECT: 'fixture-project',
      MECHANICIAN_VERTEX_REGION: 'global',
      MECHANICIAN_CONFIG_DIR: support,
      MECHANICIAN_CWD: support,
      ANTHROPIC_API_KEY: '',
      ANTHROPIC_AUTH_TOKEN: '',
      CLAUDE_CODE_OAUTH_TOKEN: '',
    },
    stdio: ['pipe', 'pipe', 'pipe'],
  })
  const events = []
  let stdout = ''
  let stderr = ''
  child.stdout.setEncoding('utf8')
  child.stderr.setEncoding('utf8')
  child.stdout.on('data', (chunk) => {
    stdout += chunk
    const lines = stdout.split('\n')
    stdout = lines.pop() ?? ''
    for (const line of lines) if (line) events.push(JSON.parse(line))
  })
  child.stderr.on('data', (chunk) => { stderr += chunk })
  const fixture = { events, get stderr() { return stderr } }
  t.after(async () => {
    if (child.exitCode === null) child.kill('SIGKILL')
    if (child.exitCode === null) {
      try { await once(child, 'exit') } catch {}
    }
    fs.rmSync(support, { recursive: true, force: true })
  })

  await waitFor(() => events.find((event) => event.type === 'ready'), 'ready event', fixture)
  child.stdin.write(`${JSON.stringify({
    type: 'send', id: 'turn-stop', convId: 'conversation-stop',
    sessionId: null, cwd: support, permissionMode: 'default',
    prompt: 'start something long',
  })}\n`)

  // The turn is registered and inside the preflight: precisely the window where Stop did nothing.
  await waitFor(
    () => fs.existsSync(capture) && fs.readFileSync(capture, 'utf8').includes('preflight-entered'),
    'credential preflight to begin', fixture,
  )
  await waitFor(
    () => events.find((event) => event.id === 'turn-stop'
      && event.type === 'status' && event.status === 'checking_credentials'),
    'checking_credentials status', fixture,
  )

  child.stdin.write(`${JSON.stringify({
    type: 'interrupt', id: 'stop-1', turnId: 'turn-stop',
  })}\n`)
  // Let the preflight finish successfully. The turn must still not run: the user cancelled it.
  await new Promise((resolve) => setTimeout(resolve, 50))
  fs.writeFileSync(release, 'go')

  const terminal = await waitFor(
    () => events.find((event) => event.id === 'turn-stop'
      && (event.type === 'done' || event.type === 'error')),
    'turn terminal', fixture,
  )

  assert.deepEqual(terminal, { type: 'done', id: 'turn-stop', interrupted: true })

  const sdkEvents = fs.readFileSync(capture, 'utf8').trim().split('\n')
  assert.equal(sdkEvents.includes('preflight-released'), true, 'the preflight should have completed')
  // The regression in one assertion: a stopped turn must never reach the provider.
  assert.equal(sdkEvents.includes('provider-query'), false,
    'a turn stopped before preparation must not be sent to the provider')
  // And no answer may reach the transcript.
  assert.equal(
    events.some((event) => event.id === 'turn-stop' && event.type === 'delta'), false,
    'a stopped turn must not stream assistant text')
})
