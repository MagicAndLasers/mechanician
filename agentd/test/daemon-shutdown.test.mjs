import assert from 'node:assert/strict'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { spawn } from 'node:child_process'
import http from 'node:http'
import { fileURLToPath, pathToFileURL } from 'node:url'
import { test } from 'node:test'

const here = path.dirname(fileURLToPath(import.meta.url))
const agentd = path.resolve(here, '../src/agentd.mjs')

function baseEnvironment(config, extra = {}) {
  return {
    ...process.env,
    MECHANICIAN_PROVIDER: 'anthropic',
    MECHANICIAN_AUTH: 'apikey',
    MECHANICIAN_CONFIG_DIR: config,
    MECHANICIAN_ENABLE_MOCK_PROVIDER: '1',
    MECHANICIAN_DRAIN_TIMEOUT_MS: '250',
    OPENAI_API_KEY: '',
    ANTHROPIC_API_KEY: '',
    ...extra,
  }
}

function writeRejectingControlSDKLoader(directory) {
  const sdkSource = `
    export function createSdkMcpServer(config) { return config }
    export function tool(name, description, schema, handler) {
      return { name, description, schema, handler }
    }

    export function query({ prompt, options }) {
      const stream = (async function* () {
        const input = prompt?.[Symbol.asyncIterator]?.()
        if (input) await input.next()
        yield {
          type: 'system', subtype: 'init', session_id: 'control-fixture-session',
          tools: ['Read'], mcp_servers: [],
        }
        await new Promise((resolve) => {
          if (options.abortController.signal.aborted) resolve()
          else options.abortController.signal.addEventListener('abort', resolve, { once: true })
        })
      })()
      stream.supportedCommands = async () => []
      stream.stopTask = async (taskId) => {
        if (taskId === 'fatal-trigger') {
          setTimeout(() => Promise.reject(new Error('independent fatal fixture')), 0)
        }
        throw new Error('stopTask rejected fixture: ' + taskId)
      }
      stream.interrupt = async () => {
        throw new Error('interrupt rejected fixture')
      }
      return stream
    }
  `
  const sdkURL = `data:text/javascript;base64,${Buffer.from(sdkSource).toString('base64')}`
  fs.writeFileSync(path.join(directory, 'control-hooks.mjs'), `
    const sdkURL = ${JSON.stringify(sdkURL)}
    export async function resolve(specifier, context, nextResolve) {
      if (specifier === '@anthropic-ai/claude-agent-sdk') {
        return { url: sdkURL, shortCircuit: true }
      }
      return nextResolve(specifier, context)
    }
  `)
  const loader = path.join(directory, 'control-loader.mjs')
  fs.writeFileSync(loader, `
    import { register } from 'node:module'
    register(new URL('./control-hooks.mjs', import.meta.url))
  `)
  return loader
}

function writeClaudeChildSDKLoader(directory) {
  const sdkSource = `
    export function createSdkMcpServer(config) { return config }
    export function tool(name, description, schema, handler) {
      return { name, description, schema, handler }
    }

    export function query({ prompt, options }) {
      const stream = (async function* () {
        const input = prompt?.[Symbol.asyncIterator]?.()
        if (input) await input.next()
        options.spawnClaudeCodeProcess({
          command: process.env.MECHANICIAN_TEST_CLAUDE_CHILD,
          args: [], cwd: process.cwd(), env: process.env,
          signal: options.abortController.signal,
        })
        yield {
          type: 'system', subtype: 'init', session_id: 'child-fixture-session',
          tools: ['Read'], mcp_servers: [],
        }
        await new Promise((resolve) => {
          if (options.abortController.signal.aborted) resolve()
          else options.abortController.signal.addEventListener('abort', resolve, { once: true })
        })
      })()
      stream.supportedCommands = async () => []
      stream.interrupt = async () => {}
      return stream
    }
  `
  const sdkURL = `data:text/javascript;base64,${Buffer.from(sdkSource).toString('base64')}`
  fs.writeFileSync(path.join(directory, 'child-hooks.mjs'), `
    const sdkURL = ${JSON.stringify(sdkURL)}
    export async function resolve(specifier, context, nextResolve) {
      if (specifier === '@anthropic-ai/claude-agent-sdk') {
        return { url: sdkURL, shortCircuit: true }
      }
      return nextResolve(specifier, context)
    }
  `)
  const loader = path.join(directory, 'child-loader.mjs')
  fs.writeFileSync(loader, `
    import { register } from 'node:module'
    register(new URL('./child-hooks.mjs', import.meta.url))
  `)
  return loader
}

function waitForExit(child, timeout = 5_000) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(
      () => reject(new Error('timed out waiting for agentd exit')), timeout)
    child.once('exit', (code, signal) => {
      clearTimeout(timer)
      resolve({ code, signal })
    })
  })
}

async function waitFor(predicate, description, timeout = 5_000) {
  const deadline = Date.now() + timeout
  while (Date.now() < deadline) {
    if (predicate()) return
    await new Promise((resolve) => setTimeout(resolve, 10))
  }
  assert.fail(`timed out waiting for ${description}`)
}

function processIsAlive(pid) {
  // `kill(0, sig)` signals the caller's whole process group and `kill(-n, sig)` a named group, so
  // a pid that failed to parse would report "alive" forever instead of failing. Only a real,
  // positive pid may be probed.
  if (!Number.isInteger(pid) || pid <= 0) return false
  try { process.kill(pid, 0); return true } catch { return false }
}

/// `echo $$ > file` creates the file before it writes the bytes, so waiting for the file to exist
/// can hand back an empty read. Under the full suite that produced pid 0, and the probe above then
/// reported the runner's own process group as the surviving child for the entire timeout.
async function readChildPID(file, description) {
  let pid = 0
  await waitFor(() => {
    if (!fs.existsSync(file)) return false
    pid = Number(fs.readFileSync(file, 'utf8').trim())
    return Number.isInteger(pid) && pid > 0
  }, description)
  return pid
}

for (const fatal of ['rejection', 'exception']) {
  test(`an unhandled ${fatal} exits nonzero through bounded cleanup`, async (t) => {
    const config = fs.mkdtempSync(path.join(os.tmpdir(), `mechanician-${fatal}-`))
    t.after(() => fs.rmSync(config, { recursive: true, force: true }))
    const trigger = fatal === 'rejection'
      ? `Promise.reject(new Error('fixture rejection'))`
      : `(() => { throw new Error('fixture exception') })()`
    const wrapper = `import(${JSON.stringify(pathToFileURL(agentd).href)}).then(() => setTimeout(() => ${trigger}, 20))`
    const child = spawn(process.execPath, ['--input-type=module', '-e', wrapper], {
      env: baseEnvironment(config),
      stdio: ['pipe', 'pipe', 'pipe'],
    })
    let stderr = ''
    child.stderr.setEncoding('utf8')
    child.stderr.on('data', (chunk) => { stderr += chunk })
    t.after(() => { if (child.exitCode == null) child.kill('SIGKILL') })

    const result = await waitForExit(child)
    assert.equal(result.code, 1)
    assert.equal(result.signal, null)
    assert.match(stderr, fatal === 'rejection' ? /UNHANDLED REJECTION/ : /UNCAUGHT EXCEPTION/)
  })
}

test('a fatal rejection aborts an active provider turn with an error before nonzero exit', async (t) => {
  const config = fs.mkdtempSync(path.join(os.tmpdir(), 'mechanician-fatal-active-'))
  t.after(() => fs.rmSync(config, { recursive: true, force: true }))
  const server = http.createServer((_request, _response) => { /* hold the provider request open */ })
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve))
  t.after(() => server.close())
  const address = server.address()
  const wrapper = `import(${JSON.stringify(pathToFileURL(agentd).href)}).then(() => setTimeout(() => Promise.reject(new Error('active fatal fixture')), 250))`
  const child = spawn(process.execPath, ['--input-type=module', '-e', wrapper], {
    env: baseEnvironment(config, {
      MECHANICIAN_PROVIDER: 'openai',
      MECHANICIAN_ENABLE_MOCK_PROVIDER: '0',
      OPENAI_API_KEY: 'test-key',
      OPENAI_BASE_URL: `http://127.0.0.1:${address.port}`,
    }),
    stdio: ['pipe', 'pipe', 'pipe'],
  })
  const events = []
  let buffered = ''
  child.stdout.setEncoding('utf8')
  child.stdout.on('data', (chunk) => {
    buffered += chunk
    const lines = buffered.split('\n')
    buffered = lines.pop() || ''
    for (const line of lines) if (line) events.push(JSON.parse(line))
  })
  t.after(() => { if (child.exitCode == null) child.kill('SIGKILL') })
  await waitFor(() => events.some((event) => event.type === 'ready'), 'ready event')
  child.stdin.write(`${JSON.stringify({ type: 'send', id: 'fatal-turn', prompt: 'hold' })}\n`)
  await waitFor(() => events.some(
    (event) => event.type === 'turn_started' && event.id === 'fatal-turn'), 'turn start')

  const result = await waitForExit(child)
  assert.equal(result.code, 1)
  assert.ok(events.some((event) => event.type === 'error'
    && event.id === 'fatal-turn'
    && event.code === 'daemon_fatal'))
  assert.equal(events.filter((event) => event.id === 'fatal-turn'
    && ['done', 'error'].includes(event.type)).length, 1)
})

test('rejected async SDK controls cannot recurse through fatal rejection cleanup', async (t) => {
  const config = fs.mkdtempSync(path.join(os.tmpdir(), 'mechanician-rejected-controls-'))
  const loader = writeRejectingControlSDKLoader(config)
  t.after(() => fs.rmSync(config, { recursive: true, force: true }))
  const child = spawn(process.execPath, ['--import', loader, agentd], {
    env: baseEnvironment(config, {
      MECHANICIAN_ENABLE_MOCK_PROVIDER: '0',
      ANTHROPIC_API_KEY: 'fixture-api-key',
    }),
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
    buffered = lines.pop() || ''
    for (const line of lines) if (line) events.push(JSON.parse(line))
  })
  child.stderr.on('data', (chunk) => { stderr += chunk })
  t.after(() => { if (child.exitCode == null) child.kill('SIGKILL') })

  await waitFor(() => events.some((event) => event.type === 'ready'), 'ready event')
  child.stdin.write(`${JSON.stringify({
    type: 'send', id: 'control-turn', convId: 'control-conversation',
    prompt: 'hold', permissionMode: 'default',
  })}\n`)
  await waitFor(() => events.some(
    (event) => event.type === 'session' && event.id === 'control-turn'), 'SDK stream start')

  child.stdin.write(`${JSON.stringify({
    type: 'stop_task', id: 'stop-handled', turnId: 'control-turn',
    taskId: 'handled-only',
  })}\n`)
  await waitFor(
    () => stderr.includes('stopTask failed: stopTask rejected fixture: handled-only'),
    'handled stopTask rejection')
  assert.equal(child.exitCode, null)
  assert.doesNotMatch(stderr, /UNHANDLED REJECTION/)

  child.stdin.write(`${JSON.stringify({
    type: 'stop_task', id: 'stop-fatal', turnId: 'control-turn',
    taskId: 'fatal-trigger',
  })}\n`)
  const result = await waitForExit(child)
  assert.equal(result.code, 1)
  assert.equal(result.signal, null)
  assert.match(stderr, /stopTask failed: stopTask rejected fixture: fatal-trigger/)
  assert.match(stderr, /interrupt failed: interrupt rejected fixture/)
  assert.match(stderr, /UNHANDLED REJECTION:.*independent fatal fixture/s)
  assert.equal(
    (stderr.match(/UNHANDLED REJECTION:/g) || []).length,
    1,
    'fatal drain must ignore reentrant unhandled rejections from its own controls')
  assert.ok(
    Buffer.byteLength(stderr) < 64 * 1024,
    `fatal cleanup log unexpectedly grew to ${Buffer.byteLength(stderr)} bytes`)
})

test('rejected async SDK controls stay nonfatal during ordinary stop and SIGTERM', async (t) => {
  const config = fs.mkdtempSync(path.join(os.tmpdir(), 'mechanician-rejected-controls-signal-'))
  const loader = writeRejectingControlSDKLoader(config)
  t.after(() => fs.rmSync(config, { recursive: true, force: true }))
  const child = spawn(process.execPath, ['--import', loader, agentd], {
    env: baseEnvironment(config, {
      MECHANICIAN_ENABLE_MOCK_PROVIDER: '0',
      ANTHROPIC_API_KEY: 'fixture-api-key',
    }),
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
    buffered = lines.pop() || ''
    for (const line of lines) if (line) events.push(JSON.parse(line))
  })
  child.stderr.on('data', (chunk) => { stderr += chunk })
  t.after(() => { if (child.exitCode == null) child.kill('SIGKILL') })

  await waitFor(() => events.some((event) => event.type === 'ready'), 'ready event')
  child.stdin.write(`${JSON.stringify({
    type: 'send', id: 'signal-control-turn', convId: 'signal-control-conversation',
    prompt: 'hold', permissionMode: 'default',
  })}\n`)
  await waitFor(() => events.some(
    (event) => event.type === 'session' && event.id === 'signal-control-turn'), 'SDK stream start')
  child.stdin.write(`${JSON.stringify({
    type: 'stop_task', id: 'signal-stop', turnId: 'signal-control-turn',
    taskId: 'handled-only',
  })}\n`)
  await waitFor(
    () => stderr.includes('stopTask failed: stopTask rejected fixture: handled-only'),
    'handled stopTask rejection')
  child.stdin.write(`${JSON.stringify({ type: 'ping', id: 'after-rejected-stop' })}\n`)
  await waitFor(
    () => events.some((event) => event.type === 'pong' && event.id === 'after-rejected-stop'),
    'pong after rejected stopTask')

  child.kill('SIGTERM')
  const result = await waitForExit(child)
  assert.equal(result.code, 0)
  assert.equal(result.signal, null)
  assert.match(stderr, /interrupt failed: interrupt rejected fixture/)
  assert.doesNotMatch(stderr, /UNHANDLED REJECTION|UNCAUGHT EXCEPTION/)
})

test('SIGTERM reaps terminal and build children before agentd exits', async (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'mechanician-shutdown-children-'))
  const bin = path.join(root, 'bin')
  const terminalPIDFile = path.join(root, 'terminal.pid')
  const buildPIDFile = path.join(root, 'build.pid')
  fs.mkdirSync(bin)
  const shell = path.join(bin, 'fixture-shell')
  const swift = path.join(bin, 'swift')
  fs.writeFileSync(shell,
    `#!/bin/sh\necho $$ > "${terminalPIDFile}"\ntrap 'exit 0' TERM INT HUP\nwhile :; do /bin/sleep 1; done\n`,
    { mode: 0o755 })
  fs.writeFileSync(swift,
    `#!/bin/sh\necho $$ > "${buildPIDFile}"\ntrap 'exit 0' TERM INT HUP\nwhile :; do /bin/sleep 1; done\n`,
    { mode: 0o755 })
  // Both fixtures are `/bin/sh` loops that outlive their parent. If this test fails before its
  // SIGTERM assertions, the hook below SIGKILLs agentd — and these reparent to launchd and spin
  // forever. That is how a machine accumulates dozens of orphaned `swift build` shells, which then
  // show up honestly in the app's own background-work chip. Kill them before removing the PID files
  // that name them, so cleanup never depends on hook ordering.
  t.after(() => {
    for (const file of [terminalPIDFile, buildPIDFile]) {
      try {
        const pid = Number(fs.readFileSync(file, 'utf8'))
        if (Number.isInteger(pid) && pid > 0) process.kill(pid, 'SIGKILL')
      } catch {}
    }
    fs.rmSync(root, { recursive: true, force: true })
  })

  const child = spawn(process.execPath, [agentd], {
    env: baseEnvironment(root, {
      PATH: `${bin}:/usr/bin:/bin`,
      SHELL: shell,
    }),
    stdio: ['pipe', 'pipe', 'pipe'],
  })
  const events = []
  let buffered = ''
  child.stdout.setEncoding('utf8')
  child.stdout.on('data', (chunk) => {
    buffered += chunk
    const lines = buffered.split('\n')
    buffered = lines.pop() || ''
    for (const line of lines) if (line) events.push(JSON.parse(line))
  })
  t.after(() => { if (child.exitCode == null) child.kill('SIGKILL') })
  await waitFor(() => events.some((event) => event.type === 'ready'), 'ready event')

  child.stdin.write(`${JSON.stringify({ type: 'term_start', id: 'term', termId: 'fixture', cwd: root })}\n`)
  child.stdin.write(`${JSON.stringify({ type: 'build_run', id: 'build', command: 'swift-build' })}\n`)
  const terminalPID = await readChildPID(terminalPIDFile, 'terminal child PID')
  const buildPID = await readChildPID(buildPIDFile, 'build child PID')

  child.kill('SIGTERM')
  const result = await waitForExit(child)
  assert.equal(result.code, 0)
  assert.equal(result.signal, null)
  // Agentd itself must still stop inside the strict five-second bound above. Under the full
  // parallel suite macOS can retain a terminated/reparented fixture process long enough for
  // kill(pid, 0) to report it for another few seconds, so give post-exit observation headroom.
  const childObservationTimeout = 15_000
  await waitFor(
    () => !processIsAlive(terminalPID),
    'terminal child exit',
    childObservationTimeout)
  await waitFor(
    () => !processIsAlive(buildPID),
    'build child exit',
    childObservationTimeout)
})

test('ordinary Claude child exit preserves intentional background work', async (t) => {
  if (process.platform === 'win32') return t.skip('POSIX process-group contract')
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'mechanician-claude-leader-exit-'))
  const loader = writeClaudeChildSDKLoader(root)
  const leaderFile = path.join(root, 'leader.pid')
  const grandchildFile = path.join(root, 'grandchild.pid')
  const cli = path.join(root, 'claude-child')
  fs.writeFileSync(cli, `#!/bin/sh
echo $$ > "${leaderFile}"
/bin/sh -c 'echo $$ > "${grandchildFile}"; trap "" TERM; while :; do /bin/sleep 1; done' &
while [ ! -s "${grandchildFile}" ]; do /bin/sleep 0.01; done
exit 0
`, { mode: 0o755 })
  t.after(() => {
    for (const file of [leaderFile, grandchildFile]) {
      try { process.kill(Number(fs.readFileSync(file, 'utf8')), 'SIGKILL') } catch {}
    }
    fs.rmSync(root, { recursive: true, force: true })
  })

  const child = spawn(process.execPath, ['--import', loader, agentd], {
    env: baseEnvironment(root, {
      MECHANICIAN_ENABLE_MOCK_PROVIDER: '0',
      MECHANICIAN_AUTH: 'bedrock',
      MECHANICIAN_BEDROCK_REGION: 'us-east-1',
      AWS_ACCESS_KEY_ID: 'fixture-access',
      AWS_SECRET_ACCESS_KEY: 'fixture-secret',
      MECHANICIAN_TEST_CLAUDE_CHILD: cli,
    }),
    stdio: ['pipe', 'pipe', 'pipe'],
  })
  const events = []
  let buffered = ''
  child.stdout.setEncoding('utf8')
  child.stdout.on('data', (chunk) => {
    buffered += chunk
    const lines = buffered.split('\n')
    buffered = lines.pop() || ''
    for (const line of lines) if (line) events.push(JSON.parse(line))
  })
  t.after(() => { if (child.exitCode == null) child.kill('SIGKILL') })
  await waitFor(() => events.some((event) => event.type === 'ready' && event.mode === 'sdk'), 'Bedrock SDK ready')
  child.stdin.write(`${JSON.stringify({
    type: 'send', id: 'leader-exit-turn', convId: 'leader-exit-conversation',
    prompt: 'spawn fixture', permissionMode: 'default',
  })}\n`)
  const leaderPID = await readChildPID(leaderFile, 'Claude leader PID')
  const grandchildPID = await readChildPID(grandchildFile, 'Claude grandchild PID')
  await waitFor(() => !processIsAlive(leaderPID), 'Claude leader exit', 5_000)
  await new Promise((resolve) => setTimeout(resolve, 250))
  assert.equal(
    processIsAlive(grandchildPID),
    true,
    'a healthy turn ending must not kill nohup/background work that FR-117 tracks separately')

  child.stdin.write(`${JSON.stringify({ type: 'ping', id: 'after-group-release' })}\n`)
  await waitFor(
    () => events.some((event) => event.type === 'pong' && event.id === 'after-group-release'),
    'daemon remains healthy after PGID release')
  child.kill('SIGTERM')
  const result = await waitForExit(child)
  assert.equal(result.code, 0)
  assert.equal(result.signal, null)
})

test('SIGTERM waits for stubborn Claude leader and grandchild process group retirement', async (t) => {
  if (process.platform === 'win32') return t.skip('POSIX process-group contract')
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'mechanician-claude-group-shutdown-'))
  const loader = writeClaudeChildSDKLoader(root)
  const leaderFile = path.join(root, 'leader.pid')
  const grandchildFile = path.join(root, 'grandchild.pid')
  const cli = path.join(root, 'claude-child')
  fs.writeFileSync(cli, `#!/bin/sh
echo $$ > "${leaderFile}"
/bin/sh -c 'echo $$ > "${grandchildFile}"; trap "" TERM; while :; do /bin/sleep 1; done' &
trap '' TERM
while :; do /bin/sleep 1; done
`, { mode: 0o755 })
  t.after(() => {
    for (const file of [leaderFile, grandchildFile]) {
      try { process.kill(Number(fs.readFileSync(file, 'utf8')), 'SIGKILL') } catch {}
    }
    fs.rmSync(root, { recursive: true, force: true })
  })

  const child = spawn(process.execPath, ['--import', loader, agentd], {
    env: baseEnvironment(root, {
      MECHANICIAN_ENABLE_MOCK_PROVIDER: '0',
      MECHANICIAN_AUTH: 'bedrock',
      MECHANICIAN_BEDROCK_REGION: 'us-east-1',
      AWS_ACCESS_KEY_ID: 'fixture-access',
      AWS_SECRET_ACCESS_KEY: 'fixture-secret',
      MECHANICIAN_TEST_CLAUDE_CHILD: cli,
    }),
    stdio: ['pipe', 'pipe', 'pipe'],
  })
  const events = []
  let buffered = ''
  child.stdout.setEncoding('utf8')
  child.stdout.on('data', (chunk) => {
    buffered += chunk
    const lines = buffered.split('\n')
    buffered = lines.pop() || ''
    for (const line of lines) if (line) events.push(JSON.parse(line))
  })
  t.after(() => { if (child.exitCode == null) child.kill('SIGKILL') })
  await waitFor(() => events.some((event) => event.type === 'ready' && event.mode === 'sdk'), 'Bedrock SDK ready')
  child.stdin.write(`${JSON.stringify({
    type: 'send', id: 'stubborn-group-turn', convId: 'stubborn-group-conversation',
    prompt: 'spawn fixture', permissionMode: 'default',
  })}\n`)
  const leaderPID = await readChildPID(leaderFile, 'stubborn Claude leader PID')
  const grandchildPID = await readChildPID(grandchildFile, 'stubborn Claude grandchild PID')

  child.kill('SIGTERM')
  const result = await waitForExit(child)
  assert.equal(result.code, 0)
  assert.equal(result.signal, null)
  assert.equal(processIsAlive(leaderPID), false, 'agentd exited before the Claude leader retired')
  assert.equal(processIsAlive(grandchildPID), false, 'agentd exited before the Claude grandchild retired')
})
