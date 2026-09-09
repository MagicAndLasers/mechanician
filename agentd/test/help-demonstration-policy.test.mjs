import assert from 'node:assert/strict'
import fs from 'node:fs'
import test from 'node:test'

import {
  MECHANICIAN_CODEX_GUIDANCE,
  codexDynamicToolNames,
} from '../src/codex-tools.mjs'
import {
  claudePlanAuthorization,
  isClaudeBuiltInAutoAllow,
  isUnattendedWithheldTool,
  localToolAuthorization,
  unattendedToolAuthorization,
  unattendedToolSpecs,
} from '../src/runtime-policy.mjs'

const corpus = JSON.parse(fs.readFileSync(
  new URL('../../help/corpus.json', import.meta.url),
  'utf8',
))
const agentdSource = fs.readFileSync(new URL('../src/agentd.mjs', import.meta.url), 'utf8')

// These are discovery calls only. They report possibilities; neither this test nor the Help corpus
// claims that a last-reported app inventory proves availability on an exact conversation route.
const READ_ONLY_INVENTORY_TOOLS = new Set([
  'DiscoverAppActions',
  'ListShortcuts',
  'ListCapabilities',
])

// Running one of these crosses from product explanation into an external Mac action. Keep the
// classification explicit so adding a new recipe cannot quietly inherit a weaker policy.
const EXTERNAL_MAC_ACTION_TOOLS = new Set([
  'RunCapability',
  'RunShortcut',
  'RunAppleScript',
  'ComputerAction',
])

// Screen capture is an external, sensitive read rather than execution. It is still interactive-only
// and therefore belongs in the unattended withholding assertion below.
const EXTERNAL_MAC_SENSITIVE_READS = new Set(['ComputerScreenshot'])

// This action stays inside Mechanician's preview pane. Runtime policy intentionally treats it as an
// additive in-app route that needs no execution approval, including in Plan and unattended work.
const IN_APP_ADDITIVE_TOOLS = new Set(['CreateOrUpdateArtifact'])

// `buildToolServers` is private, and importing agentd.mjs starts the daemon. This map plus the
// bounded source check below is the narrowest test seam that proves the server/tool pair from which
// the Claude SDK deterministically forms `mcp__<server>__<tool>`. Authorization is tested through
// exported policy functions rather than inferred from source.
const CLAUDE_HELP_TOOL_CONTRACT = new Map([
  ['CreateOrUpdateArtifact', {
    server: 'artifacts', exactName: 'mcp__artifacts__CreateOrUpdateArtifact',
    autoAllow: true, plan: 'allow',
  }],
  ['DiscoverAppActions', {
    server: 'shortcuts', exactName: 'mcp__shortcuts__DiscoverAppActions',
    autoAllow: true, plan: 'allow',
  }],
  ['ListCapabilities', {
    server: 'capabilities', exactName: 'mcp__capabilities__ListCapabilities',
    autoAllow: true, plan: 'allow',
  }],
  ['ListShortcuts', {
    server: 'shortcuts', exactName: 'mcp__shortcuts__ListShortcuts',
    autoAllow: true, plan: 'allow',
  }],
  ['RunCapability', {
    server: 'capabilities', exactName: 'mcp__capabilities__RunCapability',
    autoAllow: false, plan: 'deny',
  }],
])

function boundedSource(startMarker, endMarker, label) {
  const start = agentdSource.indexOf(startMarker)
  assert.notEqual(start, -1, `${label} start marker must exist`)
  const end = agentdSource.indexOf(endMarker, start + startMarker.length)
  assert.notEqual(end, -1, `${label} end marker must exist after its start`)
  return agentdSource.slice(start, end)
}

const demonstrations = corpus.demonstrations
assert.ok(Array.isArray(demonstrations) && demonstrations.length > 0,
  'Help must declare at least one demonstration')

const requiredToolNames = new Set()
for (const demonstration of demonstrations) {
  const tools = demonstration?.requirements?.tools
  assert.ok(Array.isArray(tools),
    `${demonstration?.id || '(unnamed demonstration)'} must declare requirements.tools`)
  for (const name of tools) {
    assert.equal(typeof name, 'string', 'demonstration tool names must be strings')
    assert.ok(name.length > 0, 'demonstration tool names must not be empty')
    requiredToolNames.add(name)
  }
}

test('every Help demonstration tool exists in the standard OpenAI and Codex surfaces', () => {
  // OpenAI's private spec array is also the input filtered into Codex dynamic specs. Keep the source
  // assertion bounded to that one declaration so a mention in guidance or a handler cannot pass it.
  const openAIToolSpecs = boundedSource(
    'const openAITools = [',
    '\nconst managedOpenAITools =',
    'standard OpenAI tool specs',
  )
  const standardTools = new Set(codexDynamicToolNames('standard'))
  for (const name of requiredToolNames) {
    assert.match(
      openAIToolSpecs,
      new RegExp(`\\bname:\\s*'${name}'`),
      `${name} is required by Help but absent from the standard OpenAI function specs`,
    )
    assert.equal(standardTools.has(name), true,
      `${name} is required by Help but absent from the standard Codex dynamic-tool profile`)
    assert.equal(MECHANICIAN_CODEX_GUIDANCE.includes(name), true,
      `${name} is required by Help but is not explained in Codex guidance`)
  }
})

test('every Help demonstration tool has an exact standard Claude MCP route and policy', () => {
  assert.deepEqual(
    [...CLAUDE_HELP_TOOL_CONTRACT.keys()].sort(),
    [...requiredToolNames].sort(),
    'the reviewed Claude alias map must cover exactly the corpus-required demonstration tools',
  )
  const standardServers = boundedSource(
    "async function buildToolServers(turnIdentity, permissionMode = 'default') {",
    '\n// --- Scheduler snapshots',
    'standard Claude in-process tool servers',
  )
  for (const [name, contract] of CLAUDE_HELP_TOOL_CONTRACT) {
    const serverMarker = `createSdkMcpServer({\n    name: '${contract.server}',`
    const serverStart = standardServers.indexOf(serverMarker)
    assert.notEqual(serverStart, -1,
      `${name} requires the Claude ${contract.server} in-process MCP server`)
    const nextServer = standardServers.indexOf('createSdkMcpServer({', serverStart + serverMarker.length)
    const serverSource = standardServers.slice(
      serverStart,
      nextServer === -1 ? standardServers.length : nextServer,
    )
    assert.match(
      serverSource,
      new RegExp(`\\btool\\(\\s*'${name}'`),
      `${name} is absent from Claude's ${contract.server} in-process MCP server`,
    )
    assert.equal(contract.exactName, `mcp__${contract.server}__${name}`, name)
    assert.equal(isClaudeBuiltInAutoAllow(contract.exactName), contract.autoAllow,
      `${contract.exactName} has the wrong Claude default-mode auto-allow policy`)
    assert.equal(claudePlanAuthorization(contract.exactName), contract.plan,
      `${contract.exactName} has the wrong Claude Plan policy`)
  }
})

test('Help demonstration requirements use only deliberately classified tool routes', () => {
  const classified = new Set([
    ...READ_ONLY_INVENTORY_TOOLS,
    ...EXTERNAL_MAC_ACTION_TOOLS,
    ...EXTERNAL_MAC_SENSITIVE_READS,
    ...IN_APP_ADDITIVE_TOOLS,
  ])
  for (const name of requiredToolNames) {
    assert.equal(classified.has(name), true,
      `${name} needs an explicit Help demonstration policy classification`)
  }
})

test('read-only demonstration inventory is allowed without granting action authority', () => {
  for (const name of READ_ONLY_INVENTORY_TOOLS) {
    if (!requiredToolNames.has(name)) continue
    assert.equal(localToolAuthorization({ name, permissionMode: 'default' }), 'allow', name)
    assert.equal(localToolAuthorization({ name, permissionMode: 'plan' }), 'allow', name)
  }
})

test('external demonstration actions prompt normally and remain denied in Plan', () => {
  for (const name of EXTERNAL_MAC_ACTION_TOOLS) {
    if (!requiredToolNames.has(name)) continue
    assert.equal(localToolAuthorization({ name, permissionMode: 'default' }), 'prompt', name)
    assert.equal(localToolAuthorization({ name, permissionMode: 'plan' }), 'deny', name)
  }
})

test('artifact demonstrations use the additive in-app route', () => {
  for (const name of IN_APP_ADDITIVE_TOOLS) {
    if (!requiredToolNames.has(name)) continue
    assert.equal(localToolAuthorization({ name, permissionMode: 'default' }), 'allow', name)
    assert.equal(localToolAuthorization({ name, permissionMode: 'plan' }), 'allow', name)
    assert.equal(isUnattendedWithheldTool(name), false, name)
    assert.equal(
      unattendedToolAuthorization({ name, permissionMode: 'dontAsk' }),
      'allow',
      name,
    )
  }
})

test('every external Mac tool is withheld from unattended runs, even Trust all', () => {
  const externalMacTools = new Set([
    ...READ_ONLY_INVENTORY_TOOLS,
    ...EXTERNAL_MAC_ACTION_TOOLS,
    ...EXTERNAL_MAC_SENSITIVE_READS,
  ])
  const specs = [...externalMacTools].map((name) => ({ name }))

  for (const name of externalMacTools) {
    assert.equal(isUnattendedWithheldTool(name), true, name)
    for (const permissionMode of ['dontAsk', 'bypassPermissions']) {
      assert.equal(
        unattendedToolAuthorization({ name, permissionMode }),
        'deny',
        `${name}/${permissionMode}`,
      )
    }
  }

  assert.deepEqual(
    unattendedToolSpecs(specs, { permissionMode: 'bypassPermissions' }),
    [],
    'Trust all must not advertise external Mac demonstration tools without a person present',
  )
})
