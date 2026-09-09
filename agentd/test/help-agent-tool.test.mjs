import assert from 'node:assert/strict'
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { test } from 'node:test'

import {
  HELP_EXPERT_TOOL_PROFILE,
  codexDynamicToolNames,
  codexDynamicToolSpecs,
} from '../src/codex-tools.mjs'
import {
  claudePlanAuthorization,
  isBoundedLocalPresentationTool,
  isClaudeBuiltInAutoAllow,
  isReadOnlyLocalTool,
  isUnattendedWithheldTool,
  localToolAuthorization,
  unattendedToolSpecs,
} from '../src/runtime-policy.mjs'

const here = path.dirname(fileURLToPath(import.meta.url))
const source = fs.readFileSync(path.join(here, '../src/agentd.mjs'), 'utf8')
const appServerSource = fs.readFileSync(path.join(here, '../src/codex-app-server.mjs'), 'utf8')

function body(startText, endText) {
  const start = source.indexOf(startText)
  assert.notEqual(start, -1, `${startText} is missing`)
  const end = source.indexOf(endText, start + startText.length)
  assert.notEqual(end, -1, `${endText} is missing after ${startText}`)
  return source.slice(start, end)
}

test('ordinary Claude, OpenAI, and Codex conversations expose signed Help and presentation tools', () => {
  const claude = body('async function buildHelpToolServer(', '\n\nasync function buildToolServers(')
  assert.match(claude, /name: 'help'/)
  assert.match(claude, /alwaysLoad: true/)
  assert.match(claude, /'SearchMechanicianHelp'/)
  assert.match(claude, /query: z\.string\(\)\.max\(1024\)/)
  assert.match(claude, /includeHistory: z\.boolean\(\)\.optional\(\)/)
  assert.match(claude, /'ShowMechanician'/)
  assert.match(claude,
    /guideID: z\.string\(\)\.max\(96\)\.regex\(\/\^\[a-z0-9\]/)
  assert.match(claude, /'RecommendMechanicianWorkflow'/)
  assert.match(claude, /goal: z\.string\(\)\.max\(1024\)/)
  assert.match(claude,
    /demonstrationID: z\.string\(\)\.max\(96\)\.regex\(\/\^\[a-z0-9\]/)
  assert.match(claude,
    /toolProfile === STANDARD_TOOL_PROFILE[\s\S]{0,160}RecommendMechanicianWorkflow/)
  assert.match(source, /scheduler,[\s\S]{0,80}\(help \? \{ help \} : \{\}\)/)

  assert.match(source, /type: 'function', name: 'SearchMechanicianHelp'/)
  assert.match(source, /type: 'function', name: 'ShowMechanician'/)
  assert.match(source,
    /guideID: \{[\s\S]{0,160}maxLength: 96,[\s\S]{0,160}pattern:/)
  assert.match(source, /type: 'function', name: 'RecommendMechanicianWorkflow'/)
  assert.match(source,
    /demonstrationID: \{[\s\S]{0,160}maxLength: 96,[\s\S]{0,160}pattern:/)
  assert.match(source, /if \(name === 'SearchMechanicianHelp'\)/)
  assert.match(source, /if \(name === 'ShowMechanician'\)/)
  assert.match(source, /if \(name === 'RecommendMechanicianWorkflow'\)/)
  // The operation tool travels the same three seams: a Claude MCP tool, an OpenAI/Codex function
  // spec, and one dispatcher branch. A tool wired into two of the three is a lane that silently
  // cannot drive the app.
  assert.match(claude, /'OperateMechanician'/)
  assert.match(claude, /operation: z\.enum\(MECHANICIAN_OPERATIONS\)/)
  assert.match(source, /type: 'function', name: 'OperateMechanician'/)
  assert.match(source, /if \(name === 'OperateMechanician'\)/)
  assert.equal(codexDynamicToolNames().includes('OperateMechanician'), true)
  assert.equal(codexDynamicToolNames().includes('SearchMechanicianHelp'), true)
  assert.equal(codexDynamicToolNames().includes('ShowMechanician'), true)
  assert.equal(codexDynamicToolNames().includes('RecommendMechanicianWorkflow'), true)
  assert.deepEqual(codexDynamicToolNames(HELP_EXPERT_TOOL_PROFILE), [
    'OperateMechanician', 'SearchMechanicianHelp', 'ShowMechanician',
  ])
  const [spec] = codexDynamicToolSpecs([{
    type: 'function',
    name: 'SearchMechanicianHelp',
    description: 'signed help',
    parameters: { type: 'object', required: ['query'] },
  }])
  assert.deepEqual(spec, {
    type: 'function',
    name: 'SearchMechanicianHelp',
    description: 'signed help',
    inputSchema: { type: 'object', required: ['query'] },
  })
})

test('ShowMechanician transports one exact guide and acknowledges only a started overlay', () => {
  const request = body('function requestShowMechanician(',
    '\n\nfunction completeShowMechanician(')
  const complete = body('function completeShowMechanician(',
    '\n\nfunction acknowledgeShowMechanician(')

  assert.match(request, /exactShowMechanicianGuideID\(input\)/)
  assert.match(request, /activeShowMechanicianRoute\(turnId, toolProfile\)/)
  assert.match(request,
    /emit\(\{ type: 'show_mechanician_request', id: turnId, reqId, guideID \}\)/)
  assert.doesNotMatch(request, /conversationID|workspaceID|selector|coordinates|script|url/i)
  assert.match(complete, /pending\.turnId !== req\?\.id/)
  assert.match(complete, /activeShowMechanicianRoute\(pending\.turnId, pending\.toolProfile\)/)
  assert.match(complete, /req\.ok === true && req\.state === 'started'/)
  assert.match(complete,
    /type: 'show_mechanician_ack', id: pending\.turnId, reqId: req\.reqId/)
  assert.match(source,
    /case 'show_mechanician_response':\s*completeShowMechanician\(req\)/)
  assert.doesNotMatch(request + complete, /library\.db|MechanicianHelp\.sqlite|ComputerAction/)
})

test('workflow advice is transported without route or requirement authority in the daemon', () => {
  const request = body('function requestWorkflowAdvice(', '\n\nfunction completeWorkflowAdvice(')
  const complete = body('function completeWorkflowAdvice(',
    '\n\nfunction acknowledgeWorkflowAdvice(')

  assert.match(request,
    /type: 'workflow_advice_request', id: turnId, reqId, goal,[\s\S]{0,160}demonstrationID/)
  assert.match(request, /WORKFLOW_ADVICE_DEMONSTRATION_ID_PATTERN\.test\(demonstrationID\)/)
  assert.doesNotMatch(request, /conversationID|workspace|permissionMode|requiredTools|coverage/)
  assert.match(request, /15_000/)
  assert.match(complete, /pending\.turnId !== req\?\.id/)
  assert.match(complete, /!ok \|\| empty \? null/)
  assert.match(complete,
    /type: 'workflow_advice_ack', id: pending\.turnId, reqId: req\.reqId/)
  assert.match(source,
    /case 'workflow_advice_response':\s*completeWorkflowAdvice\(req\)/)
  assert.doesNotMatch(request + complete, /MechanicianHelp\.sqlite|library\.db/)
})

test('the daemon only transports Help while Swift owns the signed corpus', () => {
  const request = body('function requestHelpSearch(', '\n\nfunction completeHelpSearch(')
  const complete = body('function completeHelpSearch(', '\n\nfunction acknowledgeHelpSearch(')

  assert.match(request, /type: 'help_search_request', id: turnId, reqId, query/)
  assert.match(request, /includeHistory === true/)
  assert.match(request, /15_000/)
  assert.match(request, /ok: false/)
  assert.match(complete, /pending\.turnId !== req\?\.id/)
  assert.match(complete, /pendingHelpSearches\.delete\(req\.reqId\)/)
  assert.match(complete, /!ok \|\| empty \? null/,
    'failed and empty searches must never produce an acknowledgement function')
  assert.match(complete, /type: 'help_search_ack', id: pending\.turnId, reqId: req\.reqId/)
  assert.doesNotMatch(request + complete, /MechanicianHelp\.sqlite|library\.db/)
  assert.doesNotMatch(request + complete, /fs\.(readFile|readFileSync|open|createReadStream)/)
  assert.match(source, /case 'help_search_response':\s*completeHelpSearch\(req\)/)
})

test('timeout and turn cancellation fail without an acknowledgement', () => {
  const request = body('function requestHelpSearch(', '\n\nfunction completeHelpSearch(')
  const cancel = body('function cancelPendingAppRequestsForTurn(',
    '\n\nfunction requestHelpSearch(')

  assert.match(request, /pendingHelpSearches\.delete\(reqId\)[\s\S]{0,180}ok: false/)
  assert.match(cancel, /for \(const \[reqId, pending\] of pendingHelpSearches\)/)
  assert.match(cancel, /pending\.turnId !== turnId/)
  assert.match(cancel, /pendingHelpSearches\.delete\(reqId\)/)
  assert.match(cancel, /pending\.resolve\(\{[\s\S]{0,120}ok: false/)
  assert.doesNotMatch(request + cancel, /help_search_ack/)

  const workflowRequest = body('function requestWorkflowAdvice(',
    '\n\nfunction completeWorkflowAdvice(')
  assert.match(workflowRequest, /pendingWorkflowAdvice\.delete\(reqId\)[\s\S]{0,180}ok: false/)
  assert.match(cancel, /for \(const \[reqId, pending\] of pendingWorkflowAdvice\)/)
  assert.match(cancel, /pendingWorkflowAdvice\.delete\(reqId\)/)
  assert.doesNotMatch(workflowRequest + cancel, /workflow_advice_ack/)

  const showRequest = body('function requestShowMechanician(',
    '\n\nfunction completeShowMechanician(')
  assert.match(showRequest,
    /pendingShowMechanician\.delete\(reqId\)[\s\S]{0,180}ok: false/)
  assert.match(cancel, /for \(const \[reqId, pending\] of pendingShowMechanician\)/)
  assert.match(cancel, /pendingShowMechanician\.delete\(reqId\)/)
  assert.doesNotMatch(showRequest + cancel, /show_mechanician_ack/)
  const interrupt = body("case 'interrupt': {", "\n    case 'computer_response':")
  assert.match(interrupt, /cancelPendingAppRequestsForTurn\(c\.id\)/)
})

test('each provider acknowledges only at its provider-facing result boundary', () => {
  const claude = body('async function buildHelpToolServer(', '\n\nasync function buildToolServers(')
  assert.ok(claude.indexOf('const result = {') < claude.indexOf('acknowledgeHelpSearch(answer)'))
  assert.ok(claude.indexOf('acknowledgeHelpSearch(answer)') < claude.indexOf('return result'))
  const workflowStart = claude.indexOf("'RecommendMechanicianWorkflow'")
  const workflowResult = claude.indexOf('const result = {', workflowStart)
  const workflowAck = claude.indexOf('acknowledgeWorkflowAdvice(answer)', workflowStart)
  const workflowReturn = claude.indexOf('return result', workflowStart)
  assert.ok(workflowStart >= 0 && workflowResult < workflowAck && workflowAck < workflowReturn)
  const showStart = claude.indexOf("'ShowMechanician'")
  const showResult = claude.indexOf('const result = {', showStart)
  const showAck = claude.indexOf('acknowledgeShowMechanician(answer)', showStart)
  const showReturn = claude.indexOf('return result', showStart)
  assert.ok(showStart >= 0 && showResult < showAck && showAck < showReturn)

  const openAI = body('const pendingProviderResultAcknowledgements = []',
    "\n    throw new Error('OpenAI tool loop exceeded 32 rounds.')")
  assert.ok(openAI.indexOf('if (!response.ok)')
    < openAI.indexOf('pendingProviderResultAcknowledgements.splice(0)'))
  assert.ok(openAI.indexOf('pendingProviderResultAcknowledgements.splice(0)')
    < openAI.indexOf('consumeOpenAISSE'))
  assert.match(openAI, /roundAcknowledgements\.push\(executed\.providerResultAcknowledgement\)/)

  const codex = body('async function handleCodexDynamicToolCall(',
    '\n\nfunction codexSandboxPolicy(')
  assert.match(codex, /CODEX_RESPONSE_WRITTEN/)
  assert.match(codex,
    /stageCodexHelpSearchDelivery\([\s\S]{0,120}executed\?\.providerResultAcknowledgement/)
  assert.match(codex, /value: providerResultAcknowledgement/)
  const codexHelpBarrier = body('function stageCodexHelpSearchDelivery(',
    '\n\nasync function handleCodexDynamicToolCall(')
  assert.ok(codexHelpBarrier.indexOf('acknowledge() === true')
    < codexHelpBarrier.indexOf('settle()'))
  assert.match(codexHelpBarrier, /state\.executing\.size > 0/)
  assert.match(appServerSource,
    /child\.stdin\.write\([\s\S]{0,250}if \(typeof onWritten === 'function'\)/)
  assert.match(appServerSource,
    /const onWritten = result\?\.\[CODEX_RESPONSE_WRITTEN\][\s\S]{0,120}this\.#write\(\{ id: message\.id, result: result \?\? \{\} \}, onWritten\)/)
})

test('signed Help is safe in interactive normal and Plan modes but withheld unattended', () => {
  assert.equal(isReadOnlyLocalTool('SearchMechanicianHelp'), true)
  assert.equal(localToolAuthorization({
    name: 'SearchMechanicianHelp', permissionMode: 'plan',
  }), 'allow')
  assert.equal(isClaudeBuiltInAutoAllow('mcp__help__SearchMechanicianHelp'), true)
  assert.equal(claudePlanAuthorization('mcp__help__SearchMechanicianHelp'), 'allow')
  assert.equal(isUnattendedWithheldTool('SearchMechanicianHelp'), true)
  assert.equal(isUnattendedWithheldTool('mcp__help__SearchMechanicianHelp'), true)
  assert.equal(isReadOnlyLocalTool('RecommendMechanicianWorkflow'), true)
  assert.equal(localToolAuthorization({
    name: 'RecommendMechanicianWorkflow', permissionMode: 'plan',
  }), 'allow')
  assert.equal(isClaudeBuiltInAutoAllow(
    'mcp__help__RecommendMechanicianWorkflow'), true)
  assert.equal(claudePlanAuthorization(
    'mcp__help__RecommendMechanicianWorkflow'), 'allow')
  assert.equal(isUnattendedWithheldTool('RecommendMechanicianWorkflow'), true)
  assert.equal(isUnattendedWithheldTool(
    'mcp__help__RecommendMechanicianWorkflow'), true)
  assert.equal(isReadOnlyLocalTool('ShowMechanician'), false,
    'bounded presentation must not be misclassified as a generic read')
  assert.equal(isBoundedLocalPresentationTool('ShowMechanician'), true)
  assert.equal(isBoundedLocalPresentationTool('mcp__help__ShowMechanician'), true)
  assert.equal(localToolAuthorization({
    name: 'ShowMechanician', permissionMode: 'plan',
  }), 'allow')
  assert.equal(isClaudeBuiltInAutoAllow('mcp__help__ShowMechanician'), true)
  assert.equal(claudePlanAuthorization('mcp__help__ShowMechanician'), 'allow')
  assert.equal(isUnattendedWithheldTool('ShowMechanician'), true)
  assert.equal(isUnattendedWithheldTool('mcp__help__ShowMechanician'), true)
  assert.deepEqual(unattendedToolSpecs([
    { type: 'function', name: 'SearchMechanicianHelp' },
    { type: 'function', name: 'RecommendMechanicianWorkflow' },
    { type: 'function', name: 'ShowMechanician' },
    { type: 'function', name: 'Read' },
  ]).map((spec) => spec.name), ['Read'])

  const claude = body('async function buildHelpToolServer(', '\n\nasync function buildToolServers(')
  assert.match(claude, /if \(mode !== 'sdk' \|\| UNATTENDED\) return null/,
    'the unattended Claude child must not construct the foreground-only Help server')
  assert.match(source, /\.\.\.\(help \? \{ help \} : \{\}\)/,
    'the unattended Claude child must not mount the foreground-only Help server')
  assert.match(claude, /SearchMechanicianHelp/)
  assert.match(claude, /RecommendMechanicianWorkflow/)
  assert.match(claude, /ShowMechanician/)

  const execution = body("if (name === 'SearchMechanicianHelp') {",
    '\n  await authorizeOpenAITool(ctx, name, input)')
  assert.ok(execution.indexOf('if (UNATTENDED)') < execution.indexOf('requestHelpSearch('),
    'a stale or forged provider call must fail before it reaches the absent app bridge')

  const codex = body('function codexThreadResumeConfiguration({',
    '\n\nfunction codexThreadStartParameters(')
  assert.match(codex,
    /UNATTENDED[\s\S]{0,160}unattendedToolSpecs\(openAITools/,
    'unattended Codex threads must not advertise foreground-only dynamic tools')
  assert.match(codex,
    /workflowAdviceAvailable[\s\S]{0,1600}tool\.name !== 'RecommendMechanicianWorkflow'/)
  assert.match(codex,
    /showMechanicianAvailable[\s\S]{0,1800}tool\.name !== 'ShowMechanician'/)
  const review = body('async function runCodexReview(', 'async function runMock(')
  assert.match(review, /workflowAdviceEnabled: false/)
  const workflowExecution = body("if (name === 'RecommendMechanicianWorkflow') {",
    '\n  await authorizeOpenAITool(ctx, name, input)')
  assert.match(workflowExecution, /ctx\.turnKind !== 'conversation'/)
  assert.ok(workflowExecution.indexOf("ctx.turnKind !== 'conversation'")
    < workflowExecution.indexOf('requestWorkflowAdvice('))
  const showExecution = body("if (name === 'ShowMechanician') {",
    '\n  await authorizeOpenAITool(ctx, name, input)')
  assert.match(showExecution, /ctx\.turnKind !== 'conversation'/)
  assert.ok(showExecution.indexOf("ctx.turnKind !== 'conversation'")
    < showExecution.indexOf('requestShowMechanician('))
})
