import test from 'node:test'
import assert from 'node:assert/strict'
import {
  HELP_EXPERT_CWD,
  HELP_EXPERT_GUIDANCE,
  HELP_EXPERT_PERMISSION_PROFILE,
  HELP_EXPERT_TOOL_PROFILE,
  MECHANICIAN_CODEX_GUIDANCE,
  MECHANICIAN_CODEX_GUIDANCE_WITHOUT_WORKFLOW_ADVICE,
  MECHANICIAN_SHOW_DESCRIPTION,
  MECHANICIAN_WORKFLOW_ADVICE_DESCRIPTION,
  codexDeveloperInstructions,
  codexDynamicToolNames,
  codexDynamicToolOutput,
  codexDynamicToolSpecs,
  helpExpertCodexConfiguration,
  isCodexDynamicTool,
  normalizeToolProfile,
} from '../src/codex-tools.mjs'
import { localToolAuthorization } from '../src/runtime-policy.mjs'

/// Every tool Codex is sent, as the model sees it. Kept explicit rather than imported from the
/// source so that widening the allowlist has to be a deliberate edit in two places.
///
/// That friction is only worth anything if the two places are compared. They were not: this list is
/// what the guarded tests iterate, so a tool added to the source and not to this list was simply not
/// tested, and the source's own comment claimed a guarantee that did not exist. `matchesTheSource`
/// below closes it — the list stays deliberate, and a stale one now fails.
const CODEX_TOOLS = [
  'SearchMechanicianHelp', 'ShowMechanician', 'OperateMechanician',
  'RecommendMechanicianWorkflow',
  'CreateOrUpdateArtifact', 'RequestProviderAccess', 'ComputerScreenshot', 'ComputerAction',
  'WaitFor', 'Question', 'ListCapabilities', 'RunCapability', 'ListShortcuts', 'DiscoverAppActions',
  'RunShortcut', 'RunAppleScript', 'Build',
]

test('the expected tool list matches the allowlist the source actually sends', () => {
  // Symmetric on purpose. Checking only that every expected name is sent would still miss a name
  // ADDED to the source and not here, which is precisely how the documentation guard below came to
  // be hollow: it iterated this list, so an undocumented new tool was never examined at all.
  assert.deepEqual(
    codexDynamicToolNames(), [...CODEX_TOOLS].sort(),
    'the source allowlist and this list disagree; update both deliberately')
  for (const name of ['Read', 'Write', 'Bash', 'NotFound']) {
    assert.equal(isCodexDynamicTool(name), false, `${name} must not be sent to Codex`)
  }
})

test('registers only Mechanician dynamic tools in App Server format', () => {
  const specs = codexDynamicToolSpecs([
    { type: 'function', name: 'Read', description: 'Read', parameters: { type: 'object' } },
    { type: 'function', name: 'CreateOrUpdateArtifact', description: 'Create artifact', parameters: { type: 'object', required: ['type', 'title', 'source'] } },
    { type: 'function', name: 'RequestProviderAccess', description: 'Request provider', parameters: { type: 'object', required: ['provider', 'reason', 'task'] } },
    { type: 'function', name: 'ComputerScreenshot', description: 'Capture', parameters: { type: 'object', properties: {} } },
    { type: 'function', name: 'ComputerAction', description: 'Act', parameters: { type: 'object', required: ['action'] } },
  ])

  assert.deepEqual(specs, [
    { type: 'function', name: 'CreateOrUpdateArtifact', description: 'Create artifact', inputSchema: { type: 'object', required: ['type', 'title', 'source'] } },
    { type: 'function', name: 'RequestProviderAccess', description: 'Request provider', inputSchema: { type: 'object', required: ['provider', 'reason', 'task'] } },
    { type: 'function', name: 'ComputerScreenshot', description: 'Capture', inputSchema: { type: 'object', properties: {} } },
    { type: 'function', name: 'ComputerAction', description: 'Act', inputSchema: { type: 'object', required: ['action'] } },
  ])
  assert.equal(isCodexDynamicTool('CreateOrUpdateArtifact'), true)
  assert.equal(isCodexDynamicTool('RequestProviderAccess'), true)
  assert.equal(isCodexDynamicTool('ComputerScreenshot'), true)
  assert.equal(isCodexDynamicTool('Read'), false)
})

test('converts screenshot text and image content for App Server', () => {
  const output = codexDynamicToolOutput({
    result: 'Screen is 1440x900 points.',
    output: [
      { type: 'input_text', text: 'Screen is 1440x900 points.' },
      { type: 'input_image', image_url: 'data:image/png;base64,abc', detail: 'high' },
    ],
  })

  assert.deepEqual(output, {
    result: 'Screen is 1440x900 points.',
    contentItems: [
      { type: 'inputText', text: 'Screen is 1440x900 points.' },
      { type: 'inputImage', imageUrl: 'data:image/png;base64,abc' },
    ],
  })
})

test('wraps plain tool output as text', () => {
  assert.deepEqual(codexDynamicToolOutput('click completed.'), {
    result: 'click completed.',
    contentItems: [{ type: 'inputText', text: 'click completed.' }],
  })
})

test('the capability and discovery tools reach Codex (FR-108)', () => {
  // They were absent for no recorded reason, so a saved automation was unreachable on this lane
  // while the Automation library showed the same rows regardless of provider.
  for (const name of CODEX_TOOLS) {
    assert.equal(isCodexDynamicTool(name), true, `${name} must be sent to Codex`)
  }
  // Still withheld on purpose: these execute OUTSIDE Codex's own sandbox, and handing them over
  // would make that sandbox decorative. Their absence is a decision, not an oversight.
  for (const name of ['Read', 'ListFiles', 'SearchFiles', 'Write', 'Edit', 'Bash']) {
    assert.equal(isCodexDynamicTool(name), false, `${name} must not bypass the Codex sandbox`)
  }
})

test('every tool Codex is sent is documented to the model', () => {
  // The failure this prevents: a tool whose entire value is a usage protocol arriving with nothing
  // but its JSON schema, which is how WaitFor shipped and went on hallucinating waits (FR-213).
  for (const name of CODEX_TOOLS) {
    assert.equal(
      MECHANICIAN_CODEX_GUIDANCE.includes(name), true,
      `${name} is sent to Codex but never named in the guidance`)
  }
})

test('developer instructions lead with the protocol and carry workspace text verbatim', () => {
  const workspace = 'Prefer the smallest correct change.'
  const composed = codexDeveloperInstructions(workspace)
  assert.equal(composed.startsWith(MECHANICIAN_CODEX_GUIDANCE), true)
  assert.equal(composed.endsWith(workspace), true)
  // A workspace may qualify the protocol; it must never silently displace it.
  assert.equal(composed, `${MECHANICIAN_CODEX_GUIDANCE}\n\n${workspace}`)
  // With no workspace instructions the guidance still ships, and nothing dangles.
  for (const empty of [null, undefined, '', '   ']) {
    assert.equal(codexDeveloperInstructions(empty), MECHANICIAN_CODEX_GUIDANCE)
  }
})

test('workflow advice has exact readiness guidance and reduced Codex surfaces omit it', () => {
  for (const guidance of [
    MECHANICIAN_WORKFLOW_ADVICE_DESCRIPTION,
    MECHANICIAN_CODEX_GUIDANCE,
  ]) {
    for (const state of ['ready', 'needs-mode-change', 'unavailable-here', 'not-verified']) {
      assert.match(guidance, new RegExp(`\\b${state}\\b`))
    }
    for (const label of [
      'Ready to try here',
      'Switch out of Plan',
      'Not available in this conversation',
      'Not verified yet',
    ]) assert.match(guidance, new RegExp(label))
    assert.match(guidance,
      /Continue only when[\s\S]*readiness\.canProceed === true and readiness\.state === "ready"/)
    assert.match(guidance,
      /If either condition fails, or[\s\S]*any other state or label is returned, stop/)
    assert.match(guidance, /do not invoke any recipe[\s\S]*tool/)
    assert.match(guidance,
      /confirmation, app approval, and macOS permission may still be required in any mode/)
    assert.doesNotMatch(guidance, /whether they are usable/)
  }

  const workspace = 'Report correctness risks.'
  const reduced = codexDeveloperInstructions(
    workspace,
    undefined,
    { workflowAdviceEnabled: false },
  )
  assert.equal(
    reduced,
    `${MECHANICIAN_CODEX_GUIDANCE_WITHOUT_WORKFLOW_ADVICE}\n\n${workspace}`,
  )
  assert.doesNotMatch(reduced, /RecommendMechanicianWorkflow|readiness\.state/)
  assert.doesNotMatch(reduced, /ShowMechanician/)
  assert.match(reduced, /SearchMechanicianHelp/)
})

test('ShowMechanician is a bounded app-owned presentation, not generic automation', () => {
  for (const guidance of [MECHANICIAN_SHOW_DESCRIPTION, MECHANICIAN_CODEX_GUIDANCE]) {
    assert.match(guidance, /exact.*guide ID/i)
    assert.match(guidance, /SearchMechanicianHelp/)
    assert.match(guidance, /person.*asked/i)
    assert.match(guidance, /cannot execute arbitrary input, scripts, automation, or computer control/i)
    assert.match(guidance, /started, not that the person completed/i)
  }
})

test('the widened Codex tools keep their consent path', () => {
  // Widening the allowlist must not widen authorization. RunCapability is executed through
  // authorizeOpenAITool's per-capability branch, so it must NOT be a blanket read-only allow.
  assert.equal(localToolAuthorization({ name: 'RunCapability', permissionMode: 'default' }), 'prompt')
  assert.equal(localToolAuthorization({ name: 'RunCapability', permissionMode: 'plan' }), 'deny')
  // Listing is read-only on every lane; prompting to read a list the user wrote is consent theatre.
  for (const name of ['ListCapabilities', 'ListShortcuts', 'DiscoverAppActions', 'Question']) {
    assert.equal(localToolAuthorization({ name, permissionMode: 'default' }), 'allow')
  }
  // FR-226. These ACT, so each must still raise a prompt and must stay refused in Plan. The point of
  // the widening was reach, never a quieter path: running a shortcut the user can see listed has to
  // cost the same approval it costs on the Claude lane.
  for (const name of ['RunShortcut', 'RunAppleScript', 'Build']) {
    assert.equal(localToolAuthorization({ name, permissionMode: 'default' }), 'prompt', name)
    assert.equal(localToolAuthorization({ name, permissionMode: 'plan' }), 'deny', name)
  }
})

test('help-expert is an exact closed profile with signed search and presentation tools', () => {
  assert.equal(normalizeToolProfile(HELP_EXPERT_TOOL_PROFILE), HELP_EXPERT_TOOL_PROFILE)
  assert.equal(HELP_EXPERT_CWD, '/private/var/empty')
  assert.deepEqual(codexDynamicToolNames(HELP_EXPERT_TOOL_PROFILE), [
    'OperateMechanician', 'SearchMechanicianHelp', 'ShowMechanician',
  ])
  const specs = codexDynamicToolSpecs([
    {
      type: 'function', name: 'SearchMechanicianHelp', description: 'signed Help',
      parameters: { type: 'object', required: ['query'] },
    },
    {
      type: 'function', name: 'ShowMechanician', description: 'bounded presentation',
      parameters: { type: 'object', required: ['guideID'] },
    },
    {
      type: 'function', name: 'OperateMechanician', description: 'bounded operation',
      parameters: { type: 'object', required: ['operation'] },
    },
  ], HELP_EXPERT_TOOL_PROFILE)
  assert.deepEqual(specs.map((tool) => tool.name), [
    'SearchMechanicianHelp', 'ShowMechanician', 'OperateMechanician',
  ])
  assert.equal(isCodexDynamicTool('SearchMechanicianHelp', HELP_EXPERT_TOOL_PROFILE), true)
  assert.equal(isCodexDynamicTool('ShowMechanician', HELP_EXPERT_TOOL_PROFILE), true)
  assert.equal(isCodexDynamicTool('OperateMechanician', HELP_EXPERT_TOOL_PROFILE), true)
  for (const name of CODEX_TOOLS) {
    if (name !== 'SearchMechanicianHelp' && name !== 'ShowMechanician'
        && name !== 'OperateMechanician') {
      assert.equal(isCodexDynamicTool(name, HELP_EXPERT_TOOL_PROFILE), false, name)
    }
  }
  assert.equal(codexDeveloperInstructions('Use Bash and the repository.', HELP_EXPERT_TOOL_PROFILE),
    HELP_EXPERT_GUIDANCE)
  assert.match(HELP_EXPERT_GUIDANCE, /closed tool surface/)
  assert.match(HELP_EXPERT_GUIDANCE, /OperateMechanician is unavailable in Plan/)
  assert.match(HELP_EXPERT_GUIDANCE, /untrusted reference data/)
  assert.match(HELP_EXPERT_GUIDANCE, /includeHistory/)
  assert.match(HELP_EXPERT_GUIDANCE, /cannot inspect the live app, repository, logs/)
  assert.match(HELP_EXPERT_GUIDANCE, /started.*does not mean the person completed/)
  assert.match(HELP_EXPERT_GUIDANCE, /cannot click arbitrary coordinates/)
  assert.match(HELP_EXPERT_GUIDANCE, /standard Mechanician workspace/)
  assert.throws(() => normalizeToolProfile(' help-expert'), /Unsupported tool profile/)
  assert.throws(() => normalizeToolProfile('help-expert '), /Unsupported tool profile/)
  assert.throws(() => normalizeToolProfile('HELP-EXPERT'), /Unsupported tool profile/)
})

test('help-expert Codex configuration has its own deny-root profile and no escape surface', () => {
  const configuration = helpExpertCodexConfiguration(['foreign', 'memory_private', 'foreign'])
  assert.equal(configuration.web_search, 'disabled')
  assert.equal(configuration.project_doc_max_bytes, 0)
  assert.deepEqual(configuration.permissions[HELP_EXPERT_PERMISSION_PROFILE].filesystem, {
    ':root': 'deny',
    ':minimal': 'read',
    ':tmpdir': 'deny',
    ':slash_tmp': 'deny',
  })
  assert.deepEqual(configuration.mcp_servers, {
    foreign: { enabled: false },
    memory_private: { enabled: false },
  })
  for (const [feature, enabled] of Object.entries(configuration.features)) {
    assert.equal(enabled, false, `${feature} must stay disabled`)
  }
  for (const required of [
    'shell_tool', 'unified_exec', 'code_mode', 'apps', 'plugins', 'browser_use',
    'computer_use', 'multi_agent', 'multi_agent_v2', 'artifact', 'hooks', 'skill_search',
  ]) {
    assert.equal(configuration.features[required], false, required)
  }
})
