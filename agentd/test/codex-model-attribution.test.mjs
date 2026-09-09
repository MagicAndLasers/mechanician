import assert from 'node:assert/strict'
import test from 'node:test'
import {
  CODEX_THREAD_MODEL_OBSERVATION_MAX_ENTRIES,
  CodexThreadModelObservations,
  codexEffectiveThreadModel,
  codexRootAgentModelEvent,
  codexThreadResumeProofSignature,
} from '../src/codex-model-attribution.mjs'
import { codexDynamicToolSpecs } from '../src/codex-tools.mjs'

test('normalizes the provider-reported thread model without request fallbacks', () => {
  assert.deepEqual(codexEffectiveThreadModel({
    model: '  gpt-5.6-codex  ',
    modelProvider: '  openai  ',
    thread: { id: 'thread-1' },
  }), {
    model: 'gpt-5.6-codex',
    modelProvider: 'openai',
  })
  assert.deepEqual(codexEffectiveThreadModel({
    model: 'gpt-5.6-codex',
    modelProvider: ' ',
  }), {
    model: 'gpt-5.6-codex',
  })
  assert.equal(codexEffectiveThreadModel({ thread: { id: 'thread-1' } }), null)
  assert.equal(codexEffectiveThreadModel({ model: '   ' }), null)
})

test('a newer notification wins over a delayed response baseline', () => {
  const observations = new CodexThreadModelObservations()
  const baseline = observations.revision
  const notification = observations.observe('thread-1', {
    model: 'gpt-rerouted',
    modelProvider: 'openai',
  })
  const accepted = observations.acceptResponse('thread-1', {
    model: 'gpt-stale-response',
    modelProvider: 'openai',
  }, baseline)

  assert.equal(accepted, notification)
  assert.equal(observations.get('thread-1').model, 'gpt-rerouted')
})

test('a response becomes the baseline when no newer notification exists', () => {
  const observations = new CodexThreadModelObservations()
  const accepted = observations.acceptResponse('thread-1', {
    model: 'gpt-response',
    modelProvider: 'openai',
  }, observations.revision)

  assert.equal(accepted.model, 'gpt-response')
  assert.equal(accepted.source, 'response')
})

test('a malformed response cannot reuse a prior configuration identity', () => {
  const observations = new CodexThreadModelObservations()
  observations.observe('thread-1', {
    model: 'gpt-prior-configuration',
    modelProvider: 'openai',
  }, 'response')
  const accepted = observations.acceptResponse(
    'thread-1',
    { thread: { id: 'thread-1' } },
    observations.revision,
  )

  assert.equal(accepted, null)
  assert.equal(observations.get('thread-1'), null)
  assert.equal(observations.getPersistent('thread-1'), null)
})

test('a turn-scoped reroute does not become the next warm turn identity', () => {
  const observations = new CodexThreadModelObservations()
  observations.observe('thread-1', {
    model: 'gpt-thread-setting',
    modelProvider: 'openai',
  }, 'response')
  observations.observe('thread-1', {
    model: 'gpt-turn-reroute',
    modelProvider: 'openai',
  }, 'model/rerouted')

  assert.equal(observations.get('thread-1').model, 'gpt-turn-reroute')
  assert.equal(observations.getPersistent('thread-1').model, 'gpt-thread-setting')

  observations.observe('thread-1', {
    model: 'gpt-new-thread-setting',
    modelProvider: 'openai',
  }, 'thread/settings/updated')
  assert.equal(observations.getPersistent('thread-1').model, 'gpt-new-thread-setting')
})

test('the per-thread observation cache has a pinned LRU cap', () => {
  assert.equal(CODEX_THREAD_MODEL_OBSERVATION_MAX_ENTRIES, 512)
  const observations = new CodexThreadModelObservations({ maxEntries: 2 })
  observations.observe('thread-a', { model: 'gpt-a' })
  observations.observe('thread-b', { model: 'gpt-b' })

  // A read refreshes A, making B the deterministic eviction candidate.
  assert.equal(observations.get('thread-a').model, 'gpt-a')
  observations.observe('thread-c', { model: 'gpt-c' })

  assert.equal(observations.maxEntries, 2)
  assert.equal(observations.size, 2)
  assert.equal(observations.get('thread-b'), null)
  assert.equal(observations.get('thread-a').model, 'gpt-a')
  assert.equal(observations.get('thread-c').model, 'gpt-c')
})

test('delete and clear release retained thread observations', () => {
  const observations = new CodexThreadModelObservations({ maxEntries: 2 })
  observations.observe('thread-a', { model: 'gpt-a' })
  observations.observe('thread-b', { model: 'gpt-b' })

  observations.delete('thread-a')
  assert.equal(observations.size, 1)
  assert.equal(observations.get('thread-a'), null)
  observations.clear()
  assert.equal(observations.size, 0)
  assert.equal(observations.get('thread-b'), null)
})

test('resume proof signatures include complete dynamic-tool schemas', () => {
  const first = {
    model: 'gpt-5.6-codex',
    dynamicTools: [{
      name: 'Ask',
      description: 'Ask the user',
      inputSchema: {
        type: 'object',
        properties: {
          question: { type: 'string' },
        },
      },
    }],
  }
  const reordered = {
    dynamicTools: [{
      inputSchema: {
        properties: {
          question: { type: 'string' },
        },
        type: 'object',
      },
      description: 'Ask the user',
      name: 'Ask',
    }],
    model: 'gpt-5.6-codex',
  }
  const changedSchema = structuredClone(reordered)
  changedSchema.dynamicTools[0].inputSchema.properties.question.maxLength = 100

  assert.equal(
    codexThreadResumeProofSignature(first),
    codexThreadResumeProofSignature(reordered),
  )
  assert.notEqual(
    codexThreadResumeProofSignature(first),
    codexThreadResumeProofSignature(changedSchema),
  )
})

test('adding ShowMechanician changes the Codex warm-thread schema generation proof', () => {
  const search = {
    type: 'function', name: 'SearchMechanicianHelp', description: 'Search signed Help.',
    parameters: {
      type: 'object', properties: { query: { type: 'string' } },
      required: ['query'], additionalProperties: false,
    },
  }
  const show = {
    type: 'function', name: 'ShowMechanician', description: 'Start a signed app guide.',
    parameters: {
      type: 'object', properties: { guideID: { type: 'string' } },
      required: ['guideID'], additionalProperties: false,
    },
  }
  const before = codexDynamicToolSpecs([search])
  const after = codexDynamicToolSpecs([search, show])

  assert.notEqual(
    codexThreadResumeProofSignature({ dynamicTools: before }),
    codexThreadResumeProofSignature({ dynamicTools: after }),
  )
})

test('builds a bounded provider-neutral root model event', () => {
  assert.deepEqual(codexRootAgentModelEvent(' turn-1 ', {
    model: ' gpt-5.6-codex ',
    modelProvider: ' openai ',
  }), {
    type: 'agent_model',
    id: 'turn-1',
    agentId: 'root',
    model: 'gpt-5.6-codex',
    modelProvider: 'openai',
  })
  assert.equal(codexRootAgentModelEvent('', { model: 'gpt-5.6-codex' }), null)
  assert.equal(codexRootAgentModelEvent('turn-1', { model: '' }), null)
})
