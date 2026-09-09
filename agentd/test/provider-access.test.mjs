import test from 'node:test'
import assert from 'node:assert/strict'

import { CODEX_LOGIN_START_PARAMS } from '../src/codex-app-server.mjs'
import { codexDynamicToolSpecs, isCodexDynamicTool } from '../src/codex-tools.mjs'
import {
  PROVIDER_ACCESS_REASON_MAX_BYTES,
  PROVIDER_ACCESS_TASK_MAX_BYTES,
  createProviderAccessBroker,
  normalizeProviderAccessRequest,
  providerAccessEvent,
  providerAccessToolResult,
  providerAccessToolSpec,
} from '../src/provider-access.mjs'

test('provider-access protocol requests only a provider family and emits bounded durable input', () => {
  const input = {
    provider: 'openai',
    reason: '  Native Codex review is required.  ',
    task: '  Review the current working tree and summarize findings.  ',
    access: 'codex_subscription',
    apiKey: 'must-not-survive',
  }
  const event = providerAccessEvent('turn-1', input)

  assert.deepEqual(event, {
    type: 'provider_access_request',
    id: 'turn-1',
    maker: 'openai',
    reason: 'Native Codex review is required.',
    task: 'Review the current working tree and summarize findings.',
  })
  assert.equal(Object.hasOwn(event, 'access'), false)
  assert.equal(Object.hasOwn(event, 'apiKey'), false)
  assert.match(providerAccessToolResult(input), /End this turn now/)
})

test('provider-access protocol rejects invalid or oversized requests', () => {
  assert.throws(() => normalizeProviderAccessRequest({
    provider: 'google', reason: 'needed', task: 'continue',
  }), /anthropic or openai/)
  assert.throws(() => normalizeProviderAccessRequest({
    provider: 'anthropic', reason: ' ', task: 'continue',
  }), /must not be empty/)
  assert.throws(() => normalizeProviderAccessRequest({
    provider: 'anthropic', reason: 'x'.repeat(PROVIDER_ACCESS_REASON_MAX_BYTES + 1), task: 'continue',
  }), /reason is too long/)
  assert.throws(() => normalizeProviderAccessRequest({
    provider: 'anthropic', reason: 'needed', task: 'x'.repeat(PROVIDER_ACCESS_TASK_MAX_BYTES + 1),
  }), /task is too long/)
})

test('OpenAI and Codex expose the same credential-neutral provider-access schema', () => {
  assert.deepEqual(Object.keys(providerAccessToolSpec.parameters.properties).sort(), [
    'provider', 'reason', 'task',
  ])
  assert.equal(providerAccessToolSpec.parameters.additionalProperties, false)
  assert.deepEqual(providerAccessToolSpec.parameters.properties.provider.enum, [
    'anthropic', 'openai',
  ])
  assert.deepEqual(codexDynamicToolSpecs([providerAccessToolSpec]), [{
    type: 'function',
    name: 'RequestProviderAccess',
    description: providerAccessToolSpec.description,
    inputSchema: providerAccessToolSpec.parameters,
  }])
  assert.equal(isCodexDynamicTool('RequestProviderAccess'), true)
})

test('Codex OAuth uses the provider-owned local success page', () => {
  assert.deepEqual(CODEX_LOGIN_START_PARAMS, {
    type: 'chatgpt',
    appBrand: 'codex',
    useHostedLoginSuccessPage: false,
  })
})

test('provider-access tool waits for the exact app-owned acknowledgement', async () => {
  const events = []
  const broker = createProviderAccessBroker({
    emit: (event) => events.push(event),
    makeRequestID: () => 'request-1',
  })
  const operation = broker.request('turn-1', {
    provider: 'openai', reason: 'Needs Codex.', task: 'Run a native review.',
  })
  assert.equal(events.length, 1)
  assert.equal(events[0].reqId, 'provider-access-request-1')
  assert.equal(broker.resolve({
    type: 'provider_access_response', id: 'wrong-turn',
    reqId: events[0].reqId, accepted: true,
  }), false)
  assert.equal(broker.resolve({
    type: 'provider_access_response', id: 'turn-1',
    reqId: events[0].reqId, accepted: true,
  }), true)
  await operation
  assert.equal(broker.resolve({
    type: 'provider_access_response', id: 'turn-1',
    reqId: events[0].reqId, accepted: true,
  }), false)
})

test('provider-access rejection and missing acknowledgement fail the tool', async () => {
  const rejectedEvents = []
  const rejected = createProviderAccessBroker({
    emit: (event) => rejectedEvents.push(event),
    makeRequestID: () => 'rejected',
  })
  const rejectedOperation = rejected.request('turn-2', {
    provider: 'anthropic', reason: 'Needs Claude.', task: 'Use a checkpoint.',
  })
  assert.equal(rejected.resolve({
    id: 'turn-2', reqId: rejectedEvents[0].reqId, accepted: false,
    message: 'Resolve the existing request first.',
  }), true)
  await assert.rejects(rejectedOperation, /existing request/i)

  const timedOut = createProviderAccessBroker({
    emit: () => {},
    makeRequestID: () => 'timeout',
    timeoutMilliseconds: 5,
  })
  await assert.rejects(timedOut.request('turn-3', {
    provider: 'openai', reason: 'Needs Codex.', task: 'Review.',
  }), /did not acknowledge/i)
})
