#!/usr/bin/env node

import { createHash } from 'node:crypto'
import { execFileSync } from 'node:child_process'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

import {
  BUNDLED_CODEX_VERSION,
  bundledCodexPath,
} from '../src/codex-runtime.mjs'

const here = path.dirname(fileURLToPath(import.meta.url))
const agentdRoot = path.resolve(here, '..')
const sourceDirectory = path.join(agentdRoot, 'src')
const lockPath = path.join(sourceDirectory, 'codex-app-server-schema.lock.json')
const codexPath = bundledCodexPath(sourceDirectory)
const outputDirectory = fs.mkdtempSync(path.join(os.tmpdir(), 'mechanician-codex-schema-'))
const writeLock = process.argv.includes('--write')

function invariant(condition, message) {
  if (!condition) throw new Error(message)
}

function readJSON(relativePath) {
  return JSON.parse(fs.readFileSync(path.join(outputDirectory, relativePath), 'utf8'))
}

function canonicalJSON(value) {
  if (Array.isArray(value)) return `[${value.map(canonicalJSON).join(',')}]`
  if (value && typeof value === 'object') {
    return `{${Object.keys(value).sort().map((key) =>
      `${JSON.stringify(key)}:${canonicalJSON(value[key])}`).join(',')}}`
  }
  return JSON.stringify(value)
}

try {
  fs.accessSync(codexPath, fs.constants.X_OK)
  const installedPackage = JSON.parse(
    fs.readFileSync(path.join(agentdRoot, 'node_modules/@openai/codex/package.json'), 'utf8'),
  )
  invariant(
    installedPackage.version === BUNDLED_CODEX_VERSION,
    `@openai/codex ${installedPackage.version} does not match ${BUNDLED_CODEX_VERSION}.`,
  )
  const binaryVersion = execFileSync(codexPath, ['--version'], { encoding: 'utf8' }).trim()
  invariant(
    binaryVersion.includes(BUNDLED_CODEX_VERSION),
    `Codex binary version ${binaryVersion} does not match ${BUNDLED_CODEX_VERSION}.`,
  )

  execFileSync(codexPath, [
    'app-server', 'generate-json-schema', '--experimental', '--out', outputDirectory,
  ], { stdio: ['ignore', 'ignore', 'inherit'] })

  const aggregate = readJSON('codex_app_server_protocol.v2.schemas.json')
  const threadReadParams = readJSON('v2/ThreadReadParams.json')
  const threadReadResponse = readJSON('v2/ThreadReadResponse.json')
  const threadStartParams = readJSON('v2/ThreadStartParams.json')
  const threadResumeParams = readJSON('v2/ThreadResumeParams.json')
  const threadResumeResponse = readJSON('v2/ThreadResumeResponse.json')
  const threadStartResponse = readJSON('v2/ThreadStartResponse.json')
  const threadStarted = readJSON('v2/ThreadStartedNotification.json')
  const threadSettingsUpdated = readJSON('v2/ThreadSettingsUpdatedNotification.json')
  const modelRerouted = readJSON('v2/ModelReroutedNotification.json')
  const threadCompactStartParams = readJSON('v2/ThreadCompactStartParams.json')
  const threadCompactStartResponse = readJSON('v2/ThreadCompactStartResponse.json')
  const contextCompacted = readJSON('v2/ContextCompactedNotification.json')
  const threadTokenUsageUpdated = readJSON('v2/ThreadTokenUsageUpdatedNotification.json')
  const threadItemsListParams = readJSON('v2/ThreadItemsListParams.json')
  const threadItemsListResponse = readJSON('v2/ThreadItemsListResponse.json')
  const turnStartParams = readJSON('v2/TurnStartParams.json')
  const turnStartResponse = readJSON('v2/TurnStartResponse.json')
  const turnSteerParams = readJSON('v2/TurnSteerParams.json')
  const threadSettingsUpdateResponse = readJSON('v2/ThreadSettingsUpdateResponse.json')
  const itemStarted = readJSON('v2/ItemStartedNotification.json')
  const itemCompleted = readJSON('v2/ItemCompletedNotification.json')
  const turnStarted = readJSON('v2/TurnStartedNotification.json')
  const turnCompleted = readJSON('v2/TurnCompletedNotification.json')
  const threadStatusChanged = readJSON('v2/ThreadStatusChangedNotification.json')
  const pluginListResponse = readJSON('v2/PluginListResponse.json')

  invariant(threadReadParams.properties?.threadId?.type === 'string',
    'thread/read must accept a string threadId.')
  invariant(threadReadParams.properties?.includeTurns?.type === 'boolean',
    'thread/read must retain includeTurns.')
  invariant(threadReadResponse.properties?.thread,
    'thread/read must return a thread.')
  invariant(threadReadResponse.definitions?.Thread?.properties?.turns?.type === 'array',
    'thread/read must return loaded turns.')
  invariant(threadResumeParams.properties?.threadId?.type === 'string',
    'thread/resume must accept a string threadId.')
  invariant(threadResumeParams.properties?.excludeTurns?.type === 'boolean',
    'thread/resume must retain excludeTurns so warm resumes do not return unused history.')
  for (const [name, params] of [
    ['thread/start', threadStartParams],
    ['thread/resume', threadResumeParams],
  ]) {
    const developerInstructionTypes = params.properties?.developerInstructions?.type || []
    invariant(
      Array.isArray(developerInstructionTypes)
        && developerInstructionTypes.includes('string')
        && developerInstructionTypes.includes('null'),
      `${name} must retain nullable developerInstructions for app-owned workspace guidance.`,
    )
    const configTypes = params.properties?.config?.type || []
    invariant(
      Array.isArray(configTypes)
        && configTypes.includes('object')
        && configTypes.includes('null')
        && params.properties?.config?.additionalProperties === true,
      `${name} must retain config overrides for folderless project-document isolation.`,
    )
  }
  invariant(turnStartParams.properties?.developerInstructions == null,
    'turn/start unexpectedly gained developerInstructions; review the thread-scoped contract.')
  invariant(turnSteerParams.properties?.threadId?.type === 'string'
      && turnSteerParams.required?.includes('threadId'),
    'turn/steer must retain its thread precondition for live guidance delivery.')
  invariant(turnSteerParams.properties?.expectedTurnId?.type === 'string'
      && turnSteerParams.required?.includes('expectedTurnId'),
    'turn/steer must retain its active-turn precondition for live guidance delivery.')
  invariant(turnSteerParams.properties?.input?.type === 'array'
      && turnSteerParams.required?.includes('input'),
    'turn/steer must retain its input array.')
  invariant(turnSteerParams.properties?.additionalContext?.additionalProperties,
    'turn/steer must retain keyed additionalContext for app-owned live guidance.')
  const additionalContextEntry = turnSteerParams.definitions?.AdditionalContextEntry
  invariant(additionalContextEntry?.properties?.value?.type === 'string'
      && additionalContextEntry.required?.includes('value'),
    'turn/steer additionalContext entries must retain string values.')
  invariant(
    additionalContextEntry?.definitions?.AdditionalContextKind?.enum?.includes('application')
      || turnSteerParams.definitions?.AdditionalContextKind?.enum?.includes('application'),
    'turn/steer additionalContext must retain the application trust label.',
  )

  // Context maintenance and model attribution both run before an ordinary turn can own the thread.
  // Pin their exact correlation fields so a protocol update cannot silently turn either path into
  // an unowned notification or make the UI display the requested model after Codex rerouted it.
  invariant(
    threadResumeResponse.required?.includes('model')
      && threadResumeResponse.properties?.model?.type === 'string',
    'thread/resume must return the provider-reported model.')
  invariant(
    threadResumeResponse.required?.includes('modelProvider')
      && threadResumeResponse.properties?.modelProvider?.type === 'string',
    'thread/resume must return the provider-reported model provider.')
  invariant(threadResumeResponse.required?.includes('thread')
      && threadResumeResponse.properties?.thread,
    'thread/resume must return thread metadata.')
  invariant(
    threadStartResponse.required?.includes('model')
      && threadStartResponse.properties?.model?.type === 'string',
    'thread/start must return the provider-reported model.')
  invariant(
    threadStartResponse.required?.includes('modelProvider')
      && threadStartResponse.properties?.modelProvider?.type === 'string',
    'thread/start must return the provider-reported model provider.')
  invariant(threadStartResponse.required?.includes('thread')
      && threadStartResponse.properties?.thread,
    'thread/start must return thread metadata.')
  invariant(threadStartResponse.properties?.instructionSources?.type === 'array',
    'thread/start must retain instructionSources diagnostics.')
  invariant(threadResumeResponse.properties?.instructionSources?.type === 'array',
    'thread/resume must retain instructionSources diagnostics.')
  invariant(turnStartResponse.properties?.turn && !turnStartResponse.properties?.model,
    'turn/start must remain model-less; thread start/resume own model attribution.')
  invariant(
    threadSettingsUpdateResponse.type === 'object'
      && Object.keys(threadSettingsUpdateResponse.properties || {}).length === 0,
    'thread/settings/update must remain an empty acknowledgement.',
  )
  invariant(threadStarted.properties?.thread,
    'thread/started must retain thread metadata.')
  const threadProperties = threadStarted.definitions?.Thread?.properties || {}
  invariant(threadProperties.id?.type === 'string',
    'thread/started thread metadata must retain its thread ID.')
  invariant(threadProperties.sessionId?.type === 'string',
    'thread/started must retain the distinct session-tree ID.')
  const parentThreadIdTypes =
    threadProperties.parentThreadId?.type || []
  invariant(
    Array.isArray(parentThreadIdTypes)
      && parentThreadIdTypes.includes('string')
      && parentThreadIdTypes.includes('null'),
    'thread/started must retain the optional parent thread ID used to discover subagents.',
  )
  invariant(threadProperties.model == null,
    'thread/started unexpectedly gained model metadata; review model attribution before using it.')
  invariant(threadSettingsUpdated.properties?.threadId?.type === 'string',
    'thread/settings/updated must retain threadId.')
  invariant(
    threadSettingsUpdated.definitions?.ThreadSettings?.properties?.model?.type === 'string',
    'thread/settings/updated must retain the provider-reported model.',
  )
  invariant(
    threadSettingsUpdated.definitions?.ThreadSettings?.properties?.modelProvider?.type === 'string',
    'thread/settings/updated must retain the provider-reported model provider.',
  )
  for (const field of ['threadId', 'turnId', 'fromModel', 'toModel']) {
    invariant(modelRerouted.properties?.[field]?.type === 'string',
      `model/rerouted must retain string ${field}.`)
  }

  invariant(threadCompactStartParams.properties?.threadId?.type === 'string',
    'thread/compact/start must accept a string threadId.')
  invariant(
    (threadCompactStartParams.required || []).length === 1
      && threadCompactStartParams.required[0] === 'threadId'
      && Object.keys(threadCompactStartParams.properties || {}).length === 1,
    'thread/compact/start must remain keyed only by provider thread ID.',
  )
  invariant(
    threadCompactStartResponse.type === 'object'
      && Object.keys(threadCompactStartResponse.properties || {}).length === 0,
    'thread/compact/start must remain an empty acceptance acknowledgement.',
  )
  for (const [name, schema, timestamp] of [
    ['item/started', itemStarted, 'startedAtMs'],
    ['item/completed', itemCompleted, 'completedAtMs'],
  ]) {
    invariant(schema.required?.includes('threadId')
        && schema.properties?.threadId?.type === 'string',
      `${name} must retain threadId for compaction ownership.`)
    invariant(schema.required?.includes('turnId')
        && schema.properties?.turnId?.type === 'string',
      `${name} must retain turnId for compaction ownership.`)
    invariant(schema.required?.includes('item') && schema.properties?.item,
      `${name} must retain its item payload.`)
    invariant(schema.required?.includes(timestamp)
        && schema.properties?.[timestamp]?.type === 'integer',
      `${name} must retain its millisecond lifecycle timestamp.`)
  }
  const contextCompactionItem = (itemStarted.definitions?.ThreadItem?.oneOf || [])
    .find((variant) => variant.properties?.type?.enum?.includes('contextCompaction'))
  invariant(
    contextCompactionItem?.properties?.id?.type === 'string'
      && contextCompactionItem.properties?.type?.enum?.length === 1
      && contextCompactionItem.properties.type.enum[0] === 'contextCompaction'
      && (contextCompactionItem.required || []).length === 2
      && contextCompactionItem.required.includes('id')
      && contextCompactionItem.required.includes('type'),
    'ThreadItem must retain an identified, payload-free contextCompaction item.',
  )
  const subagentActivityItem = (itemStarted.definitions?.ThreadItem?.oneOf || [])
    .find((variant) => variant.properties?.type?.enum?.includes('subAgentActivity'))
  invariant(subagentActivityItem?.properties?.agentThreadId?.type === 'string',
    'subAgentActivity must retain the authoritative child thread ID.')
  invariant(subagentActivityItem?.properties?.model == null,
    'subAgentActivity unexpectedly gained model metadata; review child attribution before using it.')
  const imageGenerationItem = (itemCompleted.definitions?.ThreadItem?.oneOf || [])
    .find((variant) => variant.properties?.type?.enum?.includes('imageGeneration'))
  invariant(
    imageGenerationItem?.properties?.id?.type === 'string'
      && imageGenerationItem.properties?.result?.type === 'string'
      && imageGenerationItem.properties?.status?.type === 'string'
      && (imageGenerationItem.required || []).includes('id')
      && (imageGenerationItem.required || []).includes('result')
      && (imageGenerationItem.required || []).includes('status'),
    'imageGeneration must retain identified terminal result and status fields.',
  )
  const imageSavedPathVariants = imageGenerationItem?.properties?.savedPath?.anyOf || []
  invariant(
    imageSavedPathVariants.some((variant) =>
      variant.$ref === '#/definitions/AbsolutePathBuf')
      && imageSavedPathVariants.some((variant) => variant.type === 'null')
      && itemCompleted.definitions?.AbsolutePathBuf?.type === 'string',
    'imageGeneration must retain nullable savedPath for durable transcript image handoff.',
  )
  invariant(contextCompacted.properties?.threadId?.type === 'string',
    'thread/compacted fallback notification must retain threadId.')
  invariant(contextCompacted.properties?.turnId?.type === 'string',
    'thread/compacted fallback notification must retain turnId.')
  invariant(threadItemsListParams.properties?.threadId?.type === 'string',
    'thread/items/list must accept threadId for compaction reconciliation.')
  invariant(
    Array.isArray(threadItemsListParams.properties?.turnId?.type)
      && threadItemsListParams.properties.turnId.type.includes('string'),
    'thread/items/list must retain its optional turn filter.',
  )
  invariant(threadItemsListResponse.properties?.data?.type === 'array',
    'thread/items/list must return item data for full compaction reconciliation.')

  for (const field of ['threadId', 'turnId']) {
    invariant(threadTokenUsageUpdated.properties?.[field]?.type === 'string',
      `thread/tokenUsage/updated must retain string ${field}.`)
  }
  const threadTokenUsage =
    threadTokenUsageUpdated.definitions?.ThreadTokenUsage?.properties || {}
  invariant(threadTokenUsage.last && threadTokenUsage.total,
    'thread/tokenUsage/updated must retain last and cumulative usage.')
  const contextWindowTypes = threadTokenUsage.modelContextWindow?.type || []
  invariant(
    Array.isArray(contextWindowTypes)
      && contextWindowTypes.includes('integer')
      && contextWindowTypes.includes('null'),
    'thread/tokenUsage/updated must retain a nullable model context window.',
  )
  const usageBreakdown =
    threadTokenUsageUpdated.definitions?.TokenUsageBreakdown || {}
  for (const field of [
    'inputTokens', 'cachedInputTokens', 'outputTokens', 'reasoningOutputTokens', 'totalTokens',
  ]) {
    invariant(
      usageBreakdown.required?.includes(field)
        && usageBreakdown.properties?.[field]?.type === 'integer',
      `Codex token usage must retain integer ${field}.`,
    )
  }

  const turnStatuses = threadReadResponse.definitions?.TurnStatus?.enum || []
  invariant(
    ['completed', 'interrupted', 'failed', 'inProgress']
      .every((status) => turnStatuses.includes(status)),
    'Codex TurnStatus no longer exposes the lifecycle states Mechanician reconciles.',
  )
  const threadStatuses = (threadReadResponse.definitions?.ThreadStatus?.oneOf || [])
    .flatMap((variant) => variant.properties?.type?.enum || [])
  invariant(
    ['notLoaded', 'idle', 'systemError', 'active']
      .every((status) => threadStatuses.includes(status)),
    'Codex ThreadStatus no longer exposes the runtime states Mechanician reconciles.',
  )
  const activeFlags = threadReadResponse.definitions?.ThreadActiveFlag?.enum || []
  invariant(
    ['waitingOnApproval', 'waitingOnUserInput']
      .every((flag) => activeFlags.includes(flag)),
    'Codex ThreadActiveFlag no longer exposes approval/input waits.',
  )

  for (const [name, schema] of [
    ['turn/started', turnStarted],
    ['turn/completed', turnCompleted],
  ]) {
    invariant(schema.properties?.threadId?.type === 'string',
      `${name} must retain threadId.`)
    invariant(schema.properties?.turn, `${name} must retain turn.`)
  }
  invariant(threadStatusChanged.properties?.threadId?.type === 'string',
    'thread/status/changed must retain threadId.')
  invariant(threadStatusChanged.properties?.status,
    'thread/status/changed must retain status.')

  // Remote plugin policy is a security boundary in the Extensions browser. `null` means the
  // service did not supply a decision, not "no interstitial", so keep both branches in the schema.
  const installationInterstitialTypes =
    pluginListResponse.definitions?.PluginSummary?.properties
      ?.mustShowInstallationInterstitial?.type || []
  invariant(
    Array.isArray(installationInterstitialTypes)
      && installationInterstitialTypes.includes('boolean')
      && installationInterstitialTypes.includes('null'),
    'PluginSummary must retain nullable mustShowInstallationInterstitial policy metadata.',
  )

  // MCP is delivered to Codex through config plus these four calls. They are pinned here because
  // the failure they guard against is silent: a renamed method leaves every configured MCP server
  // quietly unmounted on the Codex lane, with working turns and missing tools.
  const mcpStatusUpdated = readJSON('v2/McpServerStatusUpdatedNotification.json')
  const mcpStatusList = readJSON('v2/ListMcpServerStatusResponse.json')

  const startupStates = mcpStatusUpdated.definitions?.McpServerStartupState?.enum || []
  invariant(
    ['starting', 'ready', 'failed', 'cancelled'].every((state) => startupStates.includes(state)),
    'Codex McpServerStartupState no longer exposes the states Mechanician maps to MCP status.',
  )
  const authStatuses = mcpStatusList.definitions?.McpAuthStatus?.enum || []
  invariant(
    ['unsupported', 'notLoggedIn', 'bearerToken', 'oAuth'].every((s) => authStatuses.includes(s)),
    'Codex McpAuthStatus no longer exposes the authentication states Mechanician reports.',
  )
  invariant(mcpStatusList.properties?.data?.type === 'array',
    'mcpServerStatus/list must return a data array.')
  invariant(
    mcpStatusUpdated.definitions?.McpServerStartupFailureReason?.enum
      ?.includes('reauthenticationRequired'),
    'Codex no longer signals reauthenticationRequired; Sign In prompts would never appear.',
  )

  // Elicitation is a SERVER-INITIATED request, so it lives in its own schema rather than the v2
  // aggregate. A mounted MCP server can send it at any time, and answering it with a JSON-RPC error
  // is how a Codex lane wedges — so the reply vocabulary is pinned too.
  const elicitationResponse = readJSON('McpServerElicitationRequestResponse.json')
  invariant(
    ['accept', 'decline', 'cancel']
      .every((a) => (elicitationResponse.definitions?.McpServerElicitationAction?.enum || [])
        .includes(a)),
    'Codex McpServerElicitationAction changed; Mechanician could no longer decline an elicitation.',
  )

  const aggregateText = canonicalJSON(aggregate)
  for (const method of [
    'thread/read', 'thread/start', 'thread/resume', 'thread/started',
    'thread/settings/update', 'thread/settings/updated',
    'thread/status/changed', 'thread/compact/start', 'thread/compacted',
    'thread/items/list', 'thread/tokenUsage/updated',
    'item/started', 'item/completed', 'model/rerouted',
    'turn/started', 'turn/completed', 'turn/steer', 'turn/interrupt',
    // Plugin policy surface.
    'plugin/list', 'plugin/install',
    // MCP surface.
    'mcpServerStatus/list', 'config/mcpServer/reload', 'mcpServer/oauth/login',
    'mcpServer/startupStatus/updated',
  ]) {
    invariant(aggregateText.includes(JSON.stringify(method)),
      `Generated App Server schema no longer contains ${method}.`)
  }

  const schemaSHA256 = createHash('sha256').update(aggregateText).digest('hex')
  const lock = {
    codexVersion: BUNDLED_CODEX_VERSION,
    schemaVariant: 'experimental-v2',
    schemaSHA256,
    requiredTurnStatuses: ['completed', 'interrupted', 'failed', 'inProgress'],
    requiredThreadStatuses: ['notLoaded', 'idle', 'systemError', 'active'],
    requiredActiveFlags: ['waitingOnApproval', 'waitingOnUserInput'],
    requiredMcpStartupStates: ['starting', 'ready', 'failed', 'cancelled'],
    requiredMcpAuthStatuses: ['unsupported', 'notLoggedIn', 'bearerToken', 'oAuth'],
    requiredMcpElicitationActions: ['accept', 'decline', 'cancel'],
  }

  if (writeLock) {
    fs.writeFileSync(lockPath, `${JSON.stringify(lock, null, 2)}\n`)
    process.stdout.write(`Updated ${path.relative(process.cwd(), lockPath)}\n`)
  } else {
    const expected = JSON.parse(fs.readFileSync(lockPath, 'utf8'))
    invariant(
      canonicalJSON(expected) === canonicalJSON(lock),
      [
        'Pinned Codex App Server schema changed.',
        `Expected ${expected.schemaSHA256 || 'no hash'}; generated ${schemaSHA256}.`,
        'Review the generated protocol and run:',
        '  npm run update:codex-schema',
      ].join('\n'),
    )
    process.stdout.write(
      `Codex ${BUNDLED_CODEX_VERSION} App Server schema verified (${schemaSHA256.slice(0, 12)}).\n`,
    )
  }
} finally {
  fs.rmSync(outputDirectory, { recursive: true, force: true })
}
