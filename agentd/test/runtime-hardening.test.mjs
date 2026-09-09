import assert from 'node:assert/strict'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { spawn } from 'node:child_process'
import { fileURLToPath } from 'node:url'
import { test } from 'node:test'

import {
  atomicWriteText,
  continueResponsesInput,
  openAIHistory,
  searchProjectText,
} from '../src/openai-runtime.mjs'
import {
  allowKeysToRemember,
  permissionRuleKey,
  rememberedAllowKey,
  suggestedAllowKeys,
  claudePlanAuthorization,
  isBuildTool,
  isClaudeBuiltInAutoAllow,
  localToolAuthorization,
  credentialStoreReadDenial,
} from '../src/runtime-policy.mjs'
import { ResponseAckCache } from '../src/response-ack-cache.mjs'

const here = path.dirname(fileURLToPath(import.meta.url))
const agentdSource = path.resolve(here, '../src/agentd.mjs')

async function waitFor(predicate, description, timeout = 5_000) {
  const deadline = Date.now() + timeout
  while (Date.now() < deadline) {
    const result = predicate()
    if (result) return result
    await new Promise((resolve) => setTimeout(resolve, 10))
  }
  assert.fail(`timed out waiting for ${description}`)
}

function startUnavailableAgentd(t) {
  const config = fs.mkdtempSync(path.join(os.tmpdir(), 'mechanician-hardening-'))
  const child = spawn(process.execPath, [agentdSource], {
    env: {
      ...process.env,
      MECHANICIAN_PROVIDER: 'anthropic',
      MECHANICIAN_AUTH: 'apikey',
      MECHANICIAN_CONFIG_DIR: config,
      MECHANICIAN_ENABLE_MOCK_PROVIDER: '',
      ANTHROPIC_API_KEY: '',
      OPENAI_API_KEY: '',
      PATH: config,
    },
    stdio: ['pipe', 'pipe', 'pipe'],
  })
  const events = []
  let buffered = ''
  child.stdout.setEncoding('utf8')
  child.stdout.on('data', (chunk) => {
    buffered += chunk
    const lines = buffered.split('\n')
    buffered = lines.pop() ?? ''
    for (const line of lines) if (line) events.push(JSON.parse(line))
  })
  t.after(() => {
    child.kill()
    fs.rmSync(config, { recursive: true, force: true })
  })
  return { child, events }
}

test('Claude auto-allow is limited to exact Mechanician built-ins', () => {
  assert.equal(isClaudeBuiltInAutoAllow('mcp__artifacts__CreateOrUpdateArtifact'), true)
  assert.equal(isClaudeBuiltInAutoAllow('mcp__ask__Question'), true)
  assert.equal(isClaudeBuiltInAutoAllow('mcp__waitmode__WaitFor'), true)
  assert.equal(isClaudeBuiltInAutoAllow('mcp__artifacts__evil__DeleteEverything'), false)
  assert.equal(isClaudeBuiltInAutoAllow('mcp__ask__evil__Mutate'), false)
  assert.equal(isClaudeBuiltInAutoAllow('ToolSearch'), true)
  assert.equal(isClaudeBuiltInAutoAllow('mcp__skills__RunAnything'), false)
  assert.equal(isClaudeBuiltInAutoAllow('mcp__dev__Build'), false)
  assert.equal(isClaudeBuiltInAutoAllow('mcp__computer__ComputerScreenshot'), false)
  assert.equal(isBuildTool('mcp__dev__Build'), true)
  assert.equal(isBuildTool('Build'), true)
})

test('Build is execution-gated and plan overrides earlier grants', () => {
  assert.equal(localToolAuthorization({ name: 'Read', permissionMode: 'plan' }), 'allow')
  assert.equal(localToolAuthorization({ name: 'Build', permissionMode: 'default' }), 'prompt')
  assert.equal(localToolAuthorization({
    name: 'Build', permissionMode: 'default', alwaysAllowed: true,
  }), 'allow')
  assert.equal(localToolAuthorization({
    name: 'Build', permissionMode: 'plan', alwaysAllowed: true,
  }), 'deny')
  assert.equal(localToolAuthorization({ name: 'Build', permissionMode: 'bypassPermissions' }), 'allow')
  assert.equal(localToolAuthorization({ name: 'ComputerScreenshot', permissionMode: 'default' }), 'prompt')
  assert.equal(localToolAuthorization({ name: 'ComputerScreenshot', permissionMode: 'plan' }), 'prompt')
  assert.equal(localToolAuthorization({
    name: 'ComputerScreenshot', permissionMode: 'plan', alwaysAllowed: true,
  }), 'allow')
})

test('bounded Mechanician operations are allowed outside Plan and denied in Plan', () => {
  for (const name of ['OperateMechanician', 'mcp__help__OperateMechanician']) {
    for (const permissionMode of ['default', 'acceptEdits', 'bypassPermissions', 'dontAsk']) {
      assert.equal(localToolAuthorization({ name, permissionMode }), 'allow',
        `${name} in ${permissionMode}`)
    }
    assert.equal(localToolAuthorization({ name, permissionMode: 'plan' }), 'deny', name)
    assert.equal(localToolAuthorization({
      name, permissionMode: 'plan', alwaysAllowed: true,
    }), 'deny', `${name} must ignore a prior grant in Plan`)
  }
  assert.equal(claudePlanAuthorization('mcp__help__OperateMechanician'), 'deny')
})

test('Claude Plan mode fails closed before remembered execution grants', () => {
  assert.equal(claudePlanAuthorization('Read'), 'allow')
  assert.equal(claudePlanAuthorization('ToolSearch'), 'allow')
  assert.equal(claudePlanAuthorization('mcp__ask__Question'), 'allow')
  assert.equal(claudePlanAuthorization('mcp__waitmode__WaitFor'), 'allow')
  assert.equal(claudePlanAuthorization('mcp__artifacts__evil__DeleteEverything'), 'deny')
  assert.equal(claudePlanAuthorization('mcp__ask__evil__Mutate'), 'deny')
  assert.equal(claudePlanAuthorization('ComputerScreenshot'), 'sensitive')
  assert.equal(claudePlanAuthorization('ExitPlanMode'), 'prompt')
  assert.equal(claudePlanAuthorization('Bash'), 'deny')
  // Mechanician's OWN namespaces keep failing closed. We know exactly what these do.
  assert.equal(claudePlanAuthorization('mcp__dev__Build'), 'deny')
  assert.equal(claudePlanAuthorization('mcp__capabilities__SaveCapability'), 'deny')
  assert.equal(claudePlanAuthorization('mcp__capabilities__RunCapability'), 'deny')
  assert.equal(claudePlanAuthorization('mcp__automation__RunAppleScript'), 'deny')
  assert.equal(claudePlanAuthorization('mcp__computer__ComputerClick'), 'deny')
  assert.equal(claudePlanAuthorization('mcp__shortcuts__RunShortcut'), 'deny')
})

test('Plan mode prompts for user connectors instead of refusing them (FR-210)', () => {
  // The pinned SDK resolves an MCP tool with no allow rule to `ask`, regardless of readOnlyHint.
  // Denying these outright made Mechanician stricter than the harness and broke the obvious case:
  // planning a migration by reading a document. The person decides; we just stop pre-empting them.
  assert.equal(claudePlanAuthorization('mcp__claude_ai_Google_Drive__search_files'), 'prompt')
  assert.equal(claudePlanAuthorization('mcp__claude_ai_Gmail__search_threads'), 'prompt')
  assert.equal(claudePlanAuthorization('mcp__github__list_pull_requests'), 'prompt')
  assert.equal(claudePlanAuthorization('mcp__external__LooksReadOnly'), 'prompt')

  // A connector cannot reach the built-in verdict by dressing up as one of our namespaces: the
  // test is a PREFIX on the full `mcp__<server>__` segment, and a server named `devious` or
  // `asking` does not start with `mcp__dev__` or `mcp__ask__`.
  assert.equal(claudePlanAuthorization('mcp__devious__Build'), 'prompt')
  assert.equal(claudePlanAuthorization('mcp__asking__Question'), 'prompt')

  // Non-MCP names still fail closed; only Mechanician mounts unprefixed tools.
  assert.equal(claudePlanAuthorization('SomeFutureBuiltIn'), 'deny')
  assert.equal(claudePlanAuthorization(''), 'deny')
  assert.equal(claudePlanAuthorization(undefined), 'deny')
})

test('Claude Plan mode keeps the actual computer screenshot tool promptable', () => {
  assert.equal(claudePlanAuthorization('mcp__computer__ComputerScreenshot'), 'sensitive')
  assert.equal(claudePlanAuthorization('ComputerScreenshot'), 'sensitive')
})

test('Bash cannot read provider or MCP credential stores into model context', () => {
  const denied = [
    'cat ~/.claude.json',
    'python3 -c "print(open(\'/Users/alice/.claude.json\').read())"',
    'cat "$HOME/.config/gcloud/application_default_credentials.json"',
    'cat ~/.aws/credentials',
    '/usr/bin/security find-generic-password -s example -w',
    'ps aux | grep -i mcp',
    '/bin/ps -ef',
    'pgrep -af claude',
  ]
  for (const command of denied) {
    assert.match(credentialStoreReadDenial('Bash', { command }), /cannot be read/i)
  }
  assert.match(
    credentialStoreReadDenial('Read', { file_path: '/Users/alice/.claude.json' }),
    /cannot be read/i,
  )
  assert.equal(credentialStoreReadDenial('Read', { file_path: './README.md' }), null)
  assert.equal(credentialStoreReadDenial('Bash', { command: 'cat ./README.md' }), null)
  assert.equal(credentialStoreReadDenial('Bash', { command: 'ls ~/.claude' }), null)
})

test('a command name only counts in command position, not anywhere a word appears', () => {
  // The guard matched `ps` after ANY whitespace, so ordinary work was refused with a message about
  // credential stores: confidently wrong, and it fires before the permission-mode branches, so it
  // hit even in bypassPermissions with no prompt and no log on the interactive lane.
  for (const command of [
    'docker ps',
    'npm run ps',
    'grep -r ps ./src',
    'swift build 2>&1 | grep ps',
    'kubectl get ps',
    'echo "ps"',
  ]) {
    assert.equal(
      credentialStoreReadDenial('Bash', { command }), null,
      `${command} is not a process-table read`)
  }

  // Still denied wherever `ps` genuinely starts a command, including after a separator or inside a
  // substitution. The process table carries provider CLI arguments, which leaked live tokens once.
  for (const command of [
    'ps',
    'ps aux',
    '/bin/ps -ef',
    'cat a.txt; ps aux',
    'swift build | ps',
    '$(ps aux)',
    'true && ps aux',
  ]) {
    assert.match(
      credentialStoreReadDenial('Bash', { command }) ?? '',
      /cannot be read/i,
      `${command} reads the process table`)
  }

  // A FILENAME is a legitimate argument in any position, so the path patterns stay unanchored.
  assert.match(
    credentialStoreReadDenial('Bash', { command: 'diff a.txt ~/.aws/credentials' }) ?? '',
    /cannot be read/i)
})

test('stateless OpenAI tool rounds retain the original conversation', () => {
  const original = [{ role: 'user', content: [{ type: 'input_text', text: 'inspect alpha' }] }]
  const firstOutput = [{ type: 'function_call', call_id: 'call-1', name: 'Read', arguments: '{}' }]
  const firstResults = [{ type: 'function_call_output', call_id: 'call-1', output: 'alpha' }]
  const secondInput = continueResponsesInput(original, firstOutput, firstResults)
  const secondOutput = [{ type: 'function_call', call_id: 'call-2', name: 'SearchFiles', arguments: '{}' }]
  const secondResults = [{ type: 'function_call_output', call_id: 'call-2', output: 'found' }]
  const thirdInput = continueResponsesInput(secondInput, secondOutput, secondResults)

  assert.deepEqual(thirdInput, [
    ...original, ...firstOutput, ...firstResults, ...secondOutput, ...secondResults,
  ])
})

test('stateless OpenAI history uses the exact provider-bound current prompt', () => {
  const input = openAIHistory([
    { role: 'user', text: 'earlier question' },
    { role: 'assistant', text: 'earlier answer' },
    { role: 'user', text: 'canonical user text' },
  ], 'canonical user text\n\n[Mechanician appended context]')

  assert.deepEqual(input.at(-1), {
    role: 'user',
    content: [{
      type: 'input_text',
      text: 'canonical user text\n\n[Mechanician appended context]',
    }],
  })
  assert.equal(input.filter((item) => item.role === 'user').length, 2)
})

test('built-in project search is literal, bounded, glob-aware, and skips hidden/dependency files', (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'mechanician-search-'))
  t.after(() => fs.rmSync(root, { recursive: true, force: true }))
  fs.mkdirSync(path.join(root, 'Sources'))
  fs.mkdirSync(path.join(root, 'node_modules'))
  fs.mkdirSync(path.join(root, '.hidden'))
  fs.writeFileSync(path.join(root, 'Sources', 'One.swift'), 'let marker = "a+b"\nmarker\n')
  fs.writeFileSync(path.join(root, 'Sources', 'Two.txt'), 'marker\n')
  fs.writeFileSync(path.join(root, 'node_modules', 'ignored.swift'), 'marker\n')
  fs.writeFileSync(path.join(root, '.hidden', 'secret.swift'), 'marker\n')

  const result = searchProjectText({ root, target: root, query: 'a+b', glob: '*.swift' })
  assert.equal(result.matches, 1)
  assert.equal(result.text, 'Sources/One.swift:1:let marker = "a+b"')

  const bounded = searchProjectText({ root, target: root, query: 'marker', maxMatches: 1 })
  assert.equal(bounded.matches, 1)
  assert.equal(bounded.truncated, true)
  assert.doesNotMatch(bounded.text, /node_modules|secret/)
})

test('OpenAI text writes replace atomically, preserve mode, and leave no sibling temporary', (t) => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'mechanician-atomic-write-'))
  t.after(() => fs.rmSync(root, { recursive: true, force: true }))
  const file = path.join(root, 'script.sh')
  fs.writeFileSync(file, 'old\n', { mode: 0o755 })

  atomicWriteText(file, 'new $& literal\n')

  assert.equal(fs.readFileSync(file, 'utf8'), 'new $& literal\n')
  assert.equal(fs.statSync(file).mode & 0o777, 0o755)
  assert.deepEqual(fs.readdirSync(root), ['script.sh'])
})

test('every Claude SDK query explicitly disables ambient setting sources', () => {
  const source = fs.readFileSync(agentdSource, 'utf8')
  // Count the conversation/probe sites that exist rather than pinning the architecture to a
  // number. Equality IS the invariant: every direct query disables ambient settings, so a future
  // site that forgets shows up as a mismatch rather than a silently wider blast radius.
  const directQueries = source.match(/\bquery\s*\(\s*\{/g)?.length || 0
  const isolatedOptions = source.match(/^\s+settingSources:\s*\[\],?$/gm)?.length || 0
  assert.ok(directQueries > 0)
  assert.equal(isolatedOptions, directQueries)
})

test('Claude conversations keep the built-in system prefix prompt-cacheable', () => {
  const source = fs.readFileSync(agentdSource, 'utf8')
  assert.match(
    source,
    /systemPrompt\s*=\s*\{\s*type:\s*'preset',\s*preset:\s*'claude_code',[\s\S]{0,500}?excludeDynamicSections:\s*true,/,
  )
})

test('the required Ask MCP server is eagerly mounted and stale dispatchers invalidate sessions', () => {
  const source = fs.readFileSync(agentdSource, 'utf8')
  assert.match(
    source,
    /const ask = createSdkMcpServer\(\{\s*name: 'ask',[\s\S]{0,500}?alwaysLoad: true,/,
  )
  assert.match(source, /ctx\.sessionInvalidationReason = 'built_in_ask_unavailable'/)
  assert.match(source, /emit\(\{ type: 'session_invalidated'/)
})

test('production missing-provider state errors instead of fabricating a mock reply', async (t) => {
  const { child, events } = startUnavailableAgentd(t)
  const ready = await waitFor(() => events.find((event) => event.type === 'ready'), 'ready')
  assert.equal(ready.mode, 'unavailable')
  child.stdin.write(`${JSON.stringify({ type: 'send', id: 'turn-unavailable', prompt: 'hello' })}\n`)
  const error = await waitFor(
    () => events.find((event) => event.type === 'error' && event.id === 'turn-unavailable'),
    'provider error',
  )
  assert.match(error.message, /Claude is unavailable/)
  assert.equal(events.some((event) => event.type === 'delta' && event.id === 'turn-unavailable'), false)
})

test('question responses receive a stable negative acknowledgement when ownership is gone', async (t) => {
  const { child, events } = startUnavailableAgentd(t)
  await waitFor(() => events.find((event) => event.type === 'ready'), 'ready')
  child.stdin.write(`${JSON.stringify({
    type: 'question_response', id: 'turn-finished', reqId: 'ask-1', responseId: 'response-1',
    answers: { choice: 'A' },
  })}\n`)
  const ack = await waitFor(
    () => events.find((event) => event.type === 'question_response_ack'),
    'question acknowledgement',
  )
  assert.deepEqual(ack, {
    type: 'question_response_ack', id: 'turn-finished', reqId: 'ask-1',
    responseId: 'response-1', accepted: false,
    message: 'This question is no longer active.',
  })
})

test('accepted question acknowledgements replay idempotently without accepting an ID collision', () => {
  const cache = new ResponseAckCache(2)
  const ack = {
    type: 'question_response_ack', id: 'turn-1', reqId: 'ask-1',
    responseId: 'response-1', accepted: true,
  }
  cache.remember('response-1', 'ask-1', ack)
  assert.deepEqual(cache.lookup('response-1', 'ask-1'), { status: 'duplicate', ack })
  assert.deepEqual(cache.lookup('response-1', 'ask-other'), { status: 'collision' })

  cache.remember('response-2', 'ask-2', { accepted: true })
  cache.remember('response-3', 'ask-3', { accepted: true })
  assert.deepEqual(cache.lookup('response-1', 'ask-1'), { status: 'missing' })
})

// ── Remembered approvals are keyed on the engine's own rule (FR-211) ────────────

// Exactly the shapes the pinned CLI builds. Verified in the binary: an exact-command rule, a
// `<prefix> *` rule, an MCP rule with `ruleContent: void 0`, and a skill offering both its name and
// its `name:*` form. Every one carries `destination: "localSettings"`, which is why Mechanician uses
// them as keys and never returns them as `updatedPermissions`.
const EXACT_BASH = [{
  type: 'addRules', behavior: 'allow', destination: 'localSettings',
  rules: [{ toolName: 'Bash', ruleContent: 'npm test' }],
}]
const PREFIX_BASH = [{
  type: 'addRules', behavior: 'allow', destination: 'localSettings',
  rules: [{ toolName: 'Bash', ruleContent: 'npm test *' }],
}]
const MCP_RULE = [{
  type: 'addRules', behavior: 'allow', destination: 'localSettings',
  rules: [{ toolName: 'mcp__github__list_pull_requests', ruleContent: undefined }],
}]

test('a permission rule renders the way the engine renders it', () => {
  assert.equal(permissionRuleKey({ toolName: 'Bash', ruleContent: 'npm test *' }), 'Bash(npm test *)')
  assert.equal(permissionRuleKey({ toolName: 'Bash', ruleContent: '  npm test  ' }), 'Bash(npm test)')
  // No content means the rule covers the whole tool, which is how MCP rules arrive.
  assert.equal(permissionRuleKey({ toolName: 'WebFetch', ruleContent: undefined }), 'WebFetch')
  assert.equal(permissionRuleKey({ toolName: 'WebFetch', ruleContent: '' }), 'WebFetch')
  assert.equal(permissionRuleKey({ toolName: '' }), null)
  assert.equal(permissionRuleKey(null), null)
})

test('only allow-rule suggestions become keys', () => {
  assert.deepEqual(suggestedAllowKeys(PREFIX_BASH), ['Bash(npm test *)'])
  assert.deepEqual(suggestedAllowKeys(MCP_RULE), ['mcp__github__list_pull_requests'])
  // A skill offers both forms and the SDK documents returning the full set.
  assert.deepEqual(suggestedAllowKeys([{
    type: 'addRules', behavior: 'allow', destination: 'localSettings',
    rules: [{ toolName: 'Skill', ruleContent: 'deploy' }, { toolName: 'Skill', ruleContent: 'deploy:*' }],
  }]), ['Skill(deploy)', 'Skill(deploy:*)'])
  // A deny suggestion, a rule removal, or a mode change is not a grant.
  assert.deepEqual(suggestedAllowKeys([{ type: 'addRules', behavior: 'deny', rules: [{ toolName: 'Bash' }] }]), [])
  assert.deepEqual(suggestedAllowKeys([{ type: 'removeRules', behavior: 'allow', rules: [{ toolName: 'Bash' }] }]), [])
  assert.deepEqual(suggestedAllowKeys([{ type: 'setMode', mode: 'acceptEdits' }]), [])
  assert.deepEqual(suggestedAllowKeys(undefined), [])
})

test('approving one command family does not approve every shell command', () => {
  // The defect: the grant was stored as the bare tool name, so this returned a grant for anything.
  const granted = new Set(['Bash(npm test *)'])
  const has = (key) => granted.has(key)
  assert.equal(rememberedAllowKey('Bash', suggestedAllowKeys(PREFIX_BASH), has), 'Bash(npm test *)')
  // A different command classifies differently, so it prompts.
  const destructive = [{
    type: 'addRules', behavior: 'allow', destination: 'localSettings',
    rules: [{ toolName: 'Bash', ruleContent: 'rm -rf /' }],
  }]
  assert.equal(rememberedAllowKey('Bash', suggestedAllowKeys(destructive), has), null)
  // And an exact grant does not answer for the prefix family, or the reverse.
  assert.equal(rememberedAllowKey('Bash', suggestedAllowKeys(EXACT_BASH), has), null)
})

test('a legacy bare grant keeps working but is never created again', () => {
  // Grants made before rules were narrowed are stored as the bare name. They are visible and
  // revocable in Settings, so retiring them silently would change permissions without saying so.
  const legacy = (key) => key === 'Bash'
  assert.equal(rememberedAllowKey('Bash', suggestedAllowKeys(PREFIX_BASH), legacy), 'Bash')
  // What a new approval stores is the engine's rule, not the bare name.
  assert.deepEqual(allowKeysToRemember('Bash', suggestedAllowKeys(PREFIX_BASH)), ['Bash(npm test *)'])
  // With no suggestion there is nothing to narrow to, so behavior is unchanged.
  assert.deepEqual(allowKeysToRemember('Bash', []), ['Bash'])
  assert.deepEqual(
    allowKeysToRemember('mcp__github__list_pull_requests', suggestedAllowKeys(MCP_RULE)),
    ['mcp__github__list_pull_requests'])
})

test('the subtraction vocabulary is frozen and the daemon reports plan-mode refusals', () => {
  // FR-224's spine. Two properties, asserted against the source because the emitter is internal to
  // the daemon and the vocabulary is the half the app mirrors.
  const source = fs.readFileSync(agentdSource, 'utf8')

  // 1. The plan-mode catch-all is the largest silent subtraction in the app. It must report.
  assert.match(
    source,
    /if \(authorization === 'deny'\)[\s\S]{0,600}emitSubtraction\(\{[\s\S]{0,300}reason: 'plan_mode_readonly'/,
    'a plan-mode refusal must emit a subtraction, not just deny')

  // 2. The reason vocabulary is a frozen Set, and `emitSubtraction` refuses anything outside it, so
  //    a typo cannot reach the app as an unrenderable marker.
  assert.match(source, /const SUBTRACTION_REASONS = new Set\(\[/)
  assert.match(
    source,
    /if \(!SUBTRACTION_SUBJECTS\.has\(subject\) \|\| !SUBTRACTION_REASONS\.has\(reason\)\)/,
    'a malformed report must be dropped at the emitter')

  // 3. Names and counts only. These rows persist in the activity ledger, so provider prose and
  //    paths must not be able to reach them; the bound is what keeps that true.
  assert.match(source, /const SUBTRACTION_NAME_LIMIT = 8/)
  assert.match(source, /const SUBTRACTION_MESSAGE_LIMIT = 200/)
})

test('the converted call sites report instead of refusing in silence', () => {
  const source = fs.readFileSync(agentdSource, 'utf8')

  // The credential boundary fires ahead of every permission-mode branch, so a wrong pattern here is
  // invisible: `docker ps` was refused as a credential read and nobody could see why.
  assert.match(
    source,
    /const credentialDenial = credentialStoreReadDenial[\s\S]{0,700}reason: 'credential_boundary'/,
    'a credential-boundary refusal must report itself')

  // `unavailable` and `errors` come out of one loader four lines apart, and only the first ever
  // reached a person. Both paths that announce them must now carry both.
  const serverReports = source.match(/reason: 'credentials_unavailable'/g) || []
  assert.equal(serverReports.length, 2,
    'both the cold and warm preparation paths must report a credentials-dropped server')
  const unreachableReports = source.match(/reason: 'network_unreachable'/g) || []
  assert.equal(unreachableReports.length, 2,
    'both preparation paths must report an unreachable server')

  // Codex's own consent channel: answered with an empty grant and nobody asked.
  assert.match(
    source,
    /const unattended = unattendedCodexReply\(method\)[\s\S]{0,900}reason: 'adapter_unimplemented'/,
    'a silently declined sandbox request must report itself')

  // A subtracted consent prompt on the Codex lane in plan mode.
  assert.match(
    source,
    /if \(automatic === 'decline'\)[\s\S]{0,500}reason: 'plan_mode_readonly'/,
    'a plan-mode decline on the Codex lane must report itself')
})
