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
const providerPromptSuggestion = '  Ship the “βeta” path as-is?\nKeep this line.  '

async function waitFor(predicate, description, fixture, timeout = 8_000) {
  const deadline = Date.now() + timeout
  while (Date.now() < deadline) {
    const value = predicate()
    if (value) return value
    await new Promise((resolve) => setTimeout(resolve, 10))
  }
  assert.fail(`timed out waiting for ${description}\nagentd stderr:\n${fixture.stderr}`)
}

function writeSDKLoader(directory, captureFile) {
  const sdkSource = `
    import fs from 'node:fs'
    const capture = ${JSON.stringify(captureFile)}
    const scenario = process.env.MECHANICIAN_CONTEXT_FIXTURE || 'recover'
    const record = (event) => fs.appendFileSync(capture, event + '\\n')
    const waitForAbort = (signal) => new Promise((resolve, reject) => {
      const abort = () => {
        const error = new Error('fixture query aborted')
        error.name = 'AbortError'
        reject(error)
      }
      if (signal?.aborted) abort()
      else signal?.addEventListener('abort', abort, { once: true })
    })
    let queryCount = 0
    let releaseConcurrentSecond = null

    export function createSdkMcpServer(config) { return config }
    export function tool(name, description, schema, handler) {
      return { name, description, schema, handler }
    }

    export function query({ prompt, options }) {
      queryCount += 1
      const attempt = queryCount
      const cacheScenario = scenario.startsWith('cache-')
      const sessionTransition = scenario === 'cache-session-mismatch'
        || scenario === 'cache-task-session-mismatch'
        || scenario === 'cache-conversation-reset'
      const responseSession = cacheScenario
        ? (sessionTransition && attempt > 2 ? 'cache-session-next' : 'cache-session')
        : (attempt === 1 ? 'overfull-session' : 'fresh-session')
      const terminalSession = sessionTransition && attempt === 2
        ? 'cache-session-next'
        : responseSession
      // A result can still close the retired response cycle after reset. The explicit SDK
      // successor remains authoritative even if that old terminal frame arrives last.
      const resultSession = scenario === 'cache-conversation-reset' && attempt === 2
        ? responseSession
        : terminalSession
      const assistantSession = scenario === 'cache-session-mismatch' && attempt === 2
        ? terminalSession
        : responseSession
      const aliasScenario = scenario.startsWith('cache-alias')
      const fableScenario = scenario === 'cache-fable'
      const aliasRemapped = scenario === 'cache-alias-remapped' && attempt > 1
      const catalogMissing = scenario === 'cache-catalog-missing'
      const catalogDuplicated = scenario === 'cache-catalog-duplicate'
      const initializationMissing = scenario === 'cache-initialization-missing'
      const baselineAliasEcho = scenario === 'cache-alias-baseline-echo'
      const requestedModel = options?.model || 'claude-opus-4-8'
      const responseContextModel = aliasScenario
        ? (aliasRemapped ? 'claude-opus-5-1[1m]' : 'claude-opus-5[1m]')
        : fableScenario ? requestedModel
        : cacheScenario ? requestedModel : 'claude-fixture'
      const responseModel = aliasScenario
        ? (aliasRemapped ? 'claude-opus-5-1' : 'claude-opus-5')
        : fableScenario ? 'claude-fable-5'
        : responseContextModel.replace(/\\[1m\\]$/i, '')
      const resultModelKey = aliasScenario || fableScenario
        ? (options?.model || 'opus[1m]')
        : responseModel
      const responseContextWindow = /\\[1m\\]$/i.test(responseContextModel) ? 1000000 : 200000
      let autoCompactEnabled = scenario !== 'apply-hangs'
      record(JSON.stringify({
        kind: 'query',
        attempt,
        resume: options?.resume || null,
        skillOverrides: options?.settings?.skillOverrides || null,
        abortAlreadySignaled: options?.abortController?.signal?.aborted === true,
        includeHookEvents: options?.includeHookEvents === true,
        promptSuggestions: options?.promptSuggestions,
      }))
      const stream = (async function* () {
        const input = prompt?.[Symbol.asyncIterator]?.()
        const first = input ? await input.next() : { done: true }
        if (first.done) return
        record(JSON.stringify({
          kind: 'prompt',
          attempt,
          text: first.value?.message?.content?.[0]?.text || '',
        }))
        if (scenario === 'stale-resume' && attempt === 1) {
          throw new Error('No conversation found for resumed fixture session')
        }
        if (scenario === 'cache-steer-before-root') {
          const guided = input ? await input.next() : { done: true }
          record(JSON.stringify({
            kind: 'guidance',
            attempt,
            text: guided.value?.message?.content?.[0]?.text || '',
          }))
        }
        if (scenario === 'cache-concurrent' && attempt === 2) {
          await new Promise((resolve) => { releaseConcurrentSecond = resolve })
        } else if (scenario === 'cache-concurrent' && attempt === 3
            && releaseConcurrentSecond) {
          releaseConcurrentSecond()
          releaseConcurrentSecond = null
        }
        yield {
          type: 'system',
          subtype: 'init',
          session_id: responseSession,
          tools: ['Read'],
          mcp_servers: [],
        }

        if (scenario === 'background-input-lifetime') {
          yield {
            type: 'system', subtype: 'background_tasks_changed',
            tasks: [{ task_id: 'workflow-1', task_type: 'workflow', description: 'Inspect files' }],
            session_id: responseSession,
          }
          yield {
            type: 'stream_event', session_id: responseSession, uuid: 'root-before-background',
            event: {
              type: 'content_block_delta',
              delta: { type: 'text_delta', text: 'The workflow is still running.' },
            },
          }
          yield {
            type: 'result', subtype: 'success', is_error: false,
            result: 'The workflow is still running.', session_id: responseSession,
            modelUsage: {},
          }

          const inputFinished = input.next()
          let inputClosed = false
          inputFinished.then(({ done }) => { inputClosed = done })
          await new Promise((resolve) => setImmediate(resolve))
          record(JSON.stringify({
            kind: 'input-lifetime', phase: 'root-result', inputClosed,
          }))

          yield {
            type: 'system', subtype: 'background_tasks_changed', tasks: [],
            session_id: responseSession,
          }
          yield {
            type: 'system', subtype: 'task_notification', task_id: 'workflow-1',
            status: 'completed', session_id: responseSession,
          }
          yield {
            type: 'result', subtype: 'success', is_error: false,
            result: 'No response requested.', num_turns: 0, session_id: responseSession,
            modelUsage: {},
          }
          await new Promise((resolve) => setImmediate(resolve))
          record(JSON.stringify({
            kind: 'input-lifetime', phase: 'notification-result', inputClosed,
          }))

          yield {
            type: 'stream_event', session_id: responseSession, uuid: 'root-after-background',
            event: {
              type: 'content_block_delta',
              delta: { type: 'text_delta', text: 'The workflow completed successfully.' },
            },
          }
          yield {
            type: 'result', subtype: 'success', is_error: false,
            result: 'The workflow completed successfully.', session_id: responseSession,
            modelUsage: {},
          }
          const finalInput = await inputFinished
          record(JSON.stringify({
            kind: 'input-lifetime', phase: 'final-result', inputClosed: finalInput.done,
          }))
          return
        }

        // A background Agent belongs to the turn that launched it even when its child work and
        // terminal lifecycle arrive at the start of the next resumed query. Bash uses the same
        // task_* protocol and is the paired fail-closed control. The duplicate positive lifecycle
        // frames reproduce provider replay after terminal cleanup.
        if ([
          'cache-task-owner-across-turns',
          'cache-task-split-child-result',
          'cache-task-terminal-tail',
          'cache-task-terminal-tail-next-query',
          'cache-task-session-reset',
          'cache-task-session-mismatch',
        ].includes(scenario)
            && attempt === 1) {
          yield {
            type: 'assistant',
            session_id: responseSession,
            uuid: 'agent-owner-frame',
            parent_tool_use_id: null,
            message: {
              id: 'agent-owner-message',
              model: 'claude-fixture',
              content: [{
                type: 'tool_use', id: 'tool-background-agent', name: 'Agent',
                input: { description: 'Inspect in the background', run_in_background: true },
              }],
              usage: {
                input_tokens: 100, cache_creation_input_tokens: 0,
                cache_read_input_tokens: 0, output_tokens: 5,
              },
            },
          }
          yield {
            type: 'system', subtype: 'task_started', session_id: responseSession,
            task_id: 'background-agent', tool_use_id: 'tool-background-agent',
            task_type: 'local_agent', subagent_type: 'Explore',
            description: 'Inspect in the background',
          }
          yield {
            type: 'user', session_id: responseSession, parent_tool_use_id: null,
            message: { content: [{
              type: 'tool_result', tool_use_id: 'tool-background-agent',
              content: 'Agent launched successfully.',
            }] },
            tool_use_result: {
              status: 'async_launched', agentId: 'background-agent',
              description: 'Inspect in the background',
            },
          }
          yield {
            type: 'assistant',
            session_id: responseSession,
            uuid: 'cancelled-agent-frame',
            parent_tool_use_id: null,
            message: {
              id: 'cancelled-agent-message',
              model: 'claude-fixture',
              content: [{
                type: 'tool_use', id: 'tool-cancelled-agent', name: 'Agent',
                input: { description: 'Wait to be cancelled', run_in_background: true },
              }],
              usage: {
                input_tokens: 100, cache_creation_input_tokens: 0,
                cache_read_input_tokens: 0, output_tokens: 5,
              },
            },
          }
          yield {
            type: 'system', subtype: 'task_started', session_id: responseSession,
            task_id: 'cancelled-agent', tool_use_id: 'tool-cancelled-agent',
            task_type: 'local_agent', subagent_type: 'Explore',
            description: 'Wait to be cancelled',
          }
          yield {
            type: 'user', session_id: responseSession, parent_tool_use_id: null,
            message: { content: [{
              type: 'tool_result', tool_use_id: 'tool-cancelled-agent',
              content: 'Agent launched successfully.',
            }] },
            tool_use_result: {
              status: 'async_launched', agentId: 'cancelled-agent',
              description: 'Wait to be cancelled',
            },
          }
          yield {
            type: 'assistant',
            session_id: responseSession,
            uuid: 'bash-owner-frame',
            parent_tool_use_id: null,
            message: {
              id: 'bash-owner-message',
              model: 'claude-fixture',
              content: [{
                type: 'tool_use', id: 'tool-background-bash', name: 'Bash',
                input: { command: 'sleep 1', run_in_background: true },
              }],
              usage: {
                input_tokens: 100, cache_creation_input_tokens: 0,
                cache_read_input_tokens: 0, output_tokens: 5,
              },
            },
          }
          yield {
            type: 'system', subtype: 'task_started', session_id: responseSession,
            task_id: 'background-bash', tool_use_id: 'tool-background-bash',
            task_type: 'local_bash', description: 'sleep 1',
          }
        }
        if (scenario === 'cache-task-split-child-result' && attempt === 1) {
          yield {
            type: 'assistant', session_id: responseSession,
            uuid: 'split-query-child-frame',
            parent_tool_use_id: 'tool-background-agent',
            subagent_type: 'Explore', task_description: 'Inspect in the background',
            message: {
              id: 'split-query-child-message', model: 'claude-child-fixture',
              content: [{
                type: 'tool_use', id: 'split-query-child-read', name: 'Read',
                input: { file_path: '/tmp/split-query' },
              }],
              usage: {
                input_tokens: 45, cache_creation_input_tokens: 0,
                cache_read_input_tokens: 0, output_tokens: 4,
              },
            },
          }
        }
        if (scenario === 'cache-task-split-child-result' && attempt === 2) {
          yield {
            type: 'user', session_id: responseSession,
            parent_tool_use_id: null,
            message: { content: [{
              type: 'tool_result', tool_use_id: 'split-query-child-read',
              content: 'split-query fixture result',
            }] },
          }
        }
        if (scenario === 'cache-task-owner-across-turns' && attempt === 2) {
          yield {
            type: 'system', subtype: 'task_updated', session_id: responseSession,
            task_id: 'cancelled-agent', tool_use_id: 'tool-cancelled-agent',
            patch: { status: 'cancelled', description: 'Cancelled by fixture' },
          }
          yield {
            type: 'assistant',
            session_id: responseSession,
            uuid: 'late-child-frame',
            parent_tool_use_id: 'tool-background-agent',
            subagent_type: 'Explore',
            task_description: 'Inspect in the background',
            message: {
              id: 'late-child-message',
              model: 'claude-child-fixture',
              content: [{
                type: 'tool_use', id: 'late-child-read', name: 'Read',
                input: { file_path: '/tmp/fixture' },
              }],
              usage: {
                input_tokens: 40, cache_creation_input_tokens: 0,
                cache_read_input_tokens: 0, output_tokens: 3,
              },
            },
          }
          yield {
            type: 'user', session_id: responseSession,
            parent_tool_use_id: 'tool-background-agent',
            message: { content: [{
              type: 'tool_result', tool_use_id: 'late-child-read', content: 'fixture result',
            }] },
          }
          yield {
            type: 'system', subtype: 'task_progress', session_id: responseSession,
            task_id: 'background-agent', summary: 'Found the fixture',
          }
          yield {
            type: 'system', subtype: 'task_notification', session_id: responseSession,
            task_id: 'background-agent', tool_use_id: 'tool-background-agent',
            status: 'completed', summary: 'Inspection complete',
          }
          yield {
            type: 'system', subtype: 'task_notification', session_id: responseSession,
            task_id: 'background-agent', tool_use_id: 'tool-background-agent',
            subagent_type: 'Explore', status: 'completed', summary: 'duplicate terminal',
          }
          yield {
            type: 'system', subtype: 'task_progress', session_id: responseSession,
            task_id: 'background-agent', tool_use_id: 'tool-background-agent',
            subagent_type: 'Explore', summary: 'duplicate progress',
          }
          yield {
            type: 'system', subtype: 'task_notification', session_id: responseSession,
            task_id: 'background-bash', tool_use_id: 'tool-background-bash',
            status: 'completed', summary: 'sleep complete',
          }
        }
        if (scenario === 'cache-task-terminal-tail' && attempt === 2) {
          yield {
            type: 'system', subtype: 'task_notification', session_id: responseSession,
            task_id: 'background-agent', tool_use_id: 'tool-background-agent',
            status: 'completed', summary: 'Parent completed before its final child frames',
          }
          yield {
            type: 'assistant', session_id: responseSession,
            uuid: 'terminal-tail-child-frame',
            parent_tool_use_id: 'tool-background-agent',
            subagent_type: 'Explore', task_description: 'Inspect in the background',
            message: {
              id: 'terminal-tail-child-message', model: 'claude-child-fixture',
              content: [
                {
                  type: 'tool_use', id: 'terminal-tail-read', name: 'Read',
                  input: { file_path: '/tmp/terminal-tail' },
                },
                {
                  type: 'tool_use', id: 'terminal-tail-nested-agent', name: 'Agent',
                  input: { description: 'Verify the tail', run_in_background: true },
                },
              ],
              usage: {
                input_tokens: 41, cache_creation_input_tokens: 0,
                cache_read_input_tokens: 0, output_tokens: 7,
              },
            },
          }
          yield {
            type: 'user', session_id: responseSession,
            parent_tool_use_id: null,
            message: { content: [{
              type: 'tool_result', tool_use_id: 'terminal-tail-read',
              content: 'tail fixture result',
            }] },
          }
          yield {
            type: 'system', subtype: 'task_started', session_id: responseSession,
            task_id: 'terminal-tail-nested-task',
            tool_use_id: 'terminal-tail-nested-agent',
            task_type: 'local_agent', subagent_type: 'general-purpose',
            description: 'Verify the tail',
          }
          yield {
            type: 'system', subtype: 'task_notification', session_id: responseSession,
            task_id: 'terminal-tail-nested-task',
            tool_use_id: 'terminal-tail-nested-agent',
            status: 'completed', summary: 'Tail verified',
          }
        }
        if (scenario === 'cache-task-terminal-tail-next-query' && attempt === 2) {
          yield {
            type: 'system', subtype: 'task_notification', session_id: responseSession,
            task_id: 'background-agent', tool_use_id: 'tool-background-agent',
            status: 'completed', summary: 'Parent completed one query before its final child frame',
          }
        }
        if (scenario === 'cache-task-terminal-tail-next-query' && attempt === 3) {
          yield {
            type: 'assistant', session_id: responseSession,
            uuid: 'next-query-tail-child-frame',
            parent_tool_use_id: 'tool-background-agent',
            subagent_type: 'Explore', task_description: 'Inspect in the background',
            message: {
              id: 'next-query-tail-child-message', model: 'claude-child-fixture',
              content: [{
                type: 'tool_use', id: 'next-query-tail-read', name: 'Read',
                input: { file_path: '/tmp/next-query-tail' },
              }],
              usage: {
                input_tokens: 42, cache_creation_input_tokens: 0,
                cache_read_input_tokens: 0, output_tokens: 8,
              },
            },
          }
          yield {
            type: 'user', session_id: responseSession,
            parent_tool_use_id: 'tool-background-agent',
            message: { content: [{
              type: 'tool_result', tool_use_id: 'next-query-tail-read',
              content: 'next-query tail result',
            }] },
          }
        }
        if (scenario === 'cache-task-session-reset' && attempt === 2) {
          yield {
            type: 'conversation_reset',
            uuid: 'task-reset-frame',
            session_id: responseSession,
            new_conversation_id: 'cache-session-next',
          }
          yield {
            type: 'assistant', session_id: responseSession,
            uuid: 'retired-session-tail-frame',
            parent_tool_use_id: 'tool-background-agent',
            subagent_type: 'Explore', task_description: 'Inspect in the background',
            message: {
              id: 'retired-session-tail-message', model: 'claude-child-fixture',
              content: [{
                type: 'tool_use', id: 'retired-session-tail-read', name: 'Read',
                input: { file_path: '/tmp/retired-session-tail' },
              }],
              usage: {
                input_tokens: 43, cache_creation_input_tokens: 0,
                cache_read_input_tokens: 0, output_tokens: 9,
              },
            },
          }
          yield {
            type: 'user', session_id: responseSession,
            parent_tool_use_id: 'tool-background-agent',
            message: { content: [{
              type: 'tool_result', tool_use_id: 'retired-session-tail-read',
              content: 'retired-session tail result',
            }] },
          }
          yield {
            type: 'system', subtype: 'task_progress', session_id: responseSession,
            task_id: 'background-agent', tool_use_id: 'tool-background-agent',
            subagent_type: 'Explore', summary: 'late retired-session replay',
          }
          yield {
            type: 'stream_event',
            session_id: 'cache-session-next',
            uuid: 'task-reset-answer-frame',
            event: {
              type: 'content_block_delta',
              delta: { type: 'text_delta', text: 'reset response' },
            },
          }
          yield {
            type: 'result', subtype: 'success', is_error: false,
            result: 'reset response', session_id: 'cache-session-next',
            modelUsage: {
              'claude-fixture': {
                inputTokens: 100, cacheReadInputTokens: 0,
                cacheCreationInputTokens: 0, contextWindow: 200000,
                canonicalModel: 'claude-fixture',
              },
            },
          }
          return
        }
        if (scenario === 'cache-task-session-mismatch' && attempt === 2) {
          yield {
            type: 'stream_event', session_id: 'cache-session-next',
            uuid: 'task-mismatch-answer-frame',
            event: {
              type: 'content_block_delta',
              delta: { type: 'text_delta', text: 'mismatch response' },
            },
          }
          yield {
            type: 'assistant', session_id: responseSession,
            uuid: 'mismatched-session-tail-frame',
            parent_tool_use_id: 'tool-background-agent',
            subagent_type: 'Explore', task_description: 'Inspect in the background',
            message: {
              id: 'mismatched-session-tail-message', model: 'claude-child-fixture',
              content: [{
                type: 'tool_use', id: 'mismatched-session-tail-read', name: 'Read',
                input: { file_path: '/tmp/mismatched-session-tail' },
              }],
              usage: {
                input_tokens: 44, cache_creation_input_tokens: 0,
                cache_read_input_tokens: 0, output_tokens: 10,
              },
            },
          }
          yield {
            type: 'user', session_id: responseSession,
            parent_tool_use_id: 'tool-background-agent',
            message: { content: [{
              type: 'tool_result', tool_use_id: 'mismatched-session-tail-read',
              content: 'mismatched-session tail result',
            }] },
          }
          yield {
            type: 'result', subtype: 'success', is_error: false,
            result: 'mismatch response', session_id: 'cache-session-next',
            modelUsage: {
              'claude-fixture': {
                inputTokens: 100, cacheReadInputTokens: 0,
                cacheCreationInputTokens: 0, contextWindow: 200000,
                canonicalModel: 'claude-fixture',
              },
            },
          }
          return
        }

        if (scenario === 'no-output-interrupt-during-replay' && attempt === 2) {
          record('fresh-replay-session-open')
          await waitForAbort(options?.abortController?.signal)
        }

      const noOutputAttempt = scenario === 'no-output-exhausted'
          || scenario === 'no-output-429'
          || scenario === 'no-output-503'
          || scenario === 'no-output-retry-429-network'
          || scenario === 'no-output-retry-network-429'
          || scenario === 'no-output-synthetic-then-error'
          || scenario === 'no-output-malformed-result'
          || scenario === 'no-output-thinking-tokens'
          || scenario === 'no-output-prompt-suggestion'
          || scenario === 'no-output-rejected-limit'
          || scenario === 'no-output-nonempty-thinking-start'
          || scenario === 'no-output-thinking-stall'
          || (attempt === 1 && scenario.startsWith('no-output-'))
      if (noOutputAttempt) {
          if (scenario === 'no-output-init-eof'
              || scenario === 'no-output-fresh-init-eof') return
          const retryStatuses = scenario === 'no-output-assistant-eof' ? []
            : scenario === 'no-output-retry-429-network' ? [429, null]
            : scenario === 'no-output-retry-network-429' ? [null, 429]
              : [scenario === 'no-output-429'
                  || scenario === 'no-output-synthetic-then-error' ? 429
                : scenario === 'no-output-503' ? 503 : null]
          for (const [retryIndex, retryStatus] of retryStatuses.entries()) {
            yield {
              type: 'system',
              subtype: 'api_retry',
              attempt: retryIndex + 1,
              max_retries: 3,
              retry_delay_ms: 0,
              error_status: retryStatus,
              error: retryStatus === 429 ? 'rate_limit'
                : retryStatus === 503 ? 'overloaded' : 'network',
              session_id: responseSession,
            }
          }
          if (scenario === 'no-output-idle-throw') {
            throw new Error('Stream idle timeout - no chunks received')
          }
          if (scenario === 'no-output-guidance') {
            const guided = input ? await input.next() : { done: true }
            record(JSON.stringify({
              kind: 'guidance',
              attempt,
              priority: guided.value?.message?.content?.[0]?.text ? 'next' : 'missing',
            }))
          }
          if (scenario === 'no-output-side-effect') {
            record('no-output-hook-effect-once')
            yield {
              type: 'system',
              subtype: 'hook_started',
              hook_id: 'prompt-hook',
              hook_name: 'fixture prompt hook',
              hook_event: 'UserPromptSubmit',
              session_id: responseSession,
            }
          }
          if (scenario === 'no-output-post-compact') {
            record('post-compact-lifecycle-once')
            for (const subtype of ['hook_started', 'hook_progress', 'hook_response']) {
              yield {
                type: 'system',
                subtype,
                hook_id: 'mechanician-post-compact',
                hook_name: 'Mechanician PostCompact observer',
                hook_event: 'PostCompact',
                session_id: responseSession,
              }
            }
            yield {
              type: 'system',
              subtype: 'compact_boundary',
              session_id: responseSession,
              compact_metadata: { trigger: 'auto', pre_tokens: 170000, post_tokens: 18000 },
            }
          }
          if (scenario === 'no-output-thinking-tokens') {
            yield {
              type: 'system', subtype: 'thinking_tokens', token_count: 1,
              session_id: responseSession,
            }
          }
          if (scenario === 'no-output-prompt-suggestion') {
            yield {
              type: 'prompt_suggestion', suggestion: 'Try something else.',
              session_id: responseSession,
            }
          }
          if (scenario === 'no-output-rejected-limit') {
            yield {
              type: 'rate_limit_event',
              rate_limit_info: { status: 'rejected', rateLimitType: 'five_hour' },
              session_id: responseSession,
            }
          }
          if (scenario === 'no-output-nonempty-thinking-start'
              || scenario === 'no-output-thinking-idle-throw') {
            yield {
              type: 'stream_event', parent_tool_use_id: null,
              session_id: responseSession,
              event: {
                type: 'content_block_start', index: 0,
                content_block: { type: 'thinking', thinking: 'provider began reasoning' },
              },
            }
          }
          if (scenario === 'no-output-thinking-idle-throw') {
            throw new Error('Stream idle timeout - no chunks received')
          }
          if (scenario === 'no-output-thinking-stall') {
            yield {
              type: 'stream_event', parent_tool_use_id: null,
              session_id: responseSession,
              event: {
                type: 'content_block_delta', index: 0,
                delta: { type: 'thinking_delta', thinking: 'still reasoning' },
              },
            }
            await waitForAbort(options?.abortController?.signal)
          }
          yield {
            type: 'assistant',
            session_id: responseSession,
            uuid: 'synthetic-no-output-' + attempt,
            parent_tool_use_id: null,
            message: {
              id: 'synthetic-no-output-message-' + attempt,
              model: '<synthetic>',
              role: 'assistant',
              content: [{ type: 'text', text: 'No response requested.' }],
              stop_reason: 'stop_sequence',
              stop_sequence: 'No response requested.',
              usage: {
                input_tokens: 0,
                cache_creation_input_tokens: 0,
                cache_read_input_tokens: 0,
                output_tokens: 0,
              },
            },
          }
          if (scenario === 'no-output-assistant-eof') return
          yield {
            type: 'result',
            uuid: 'synthetic-no-output-result-' + attempt,
            subtype: 'success',
            is_error: false,
            result: 'No response requested.',
            stop_reason: 'stop_sequence',
            duration_ms: 43,
            duration_api_ms: 0,
            num_turns: 0,
            total_cost_usd: scenario === 'no-output-malformed-result' ? 0.01 : 0,
            usage: {
              input_tokens: 0,
              cache_creation_input_tokens: 0,
              cache_read_input_tokens: 0,
              output_tokens: 0,
            },
            modelUsage: { '<synthetic>': {
              inputTokens: 0,
              cacheCreationInputTokens: 0,
              cacheReadInputTokens: 0,
              outputTokens: 0,
              webSearchRequests: 0,
              costUSD: 0,
              contextWindow: 200000,
              maxOutputTokens: 32000,
            } },
            permission_denials: [],
            session_id: responseSession,
          }
          if (scenario === 'no-output-interrupt-before-replay' && attempt === 1) {
            record('original-synthetic-terminal-held')
            await waitForAbort(options?.abortController?.signal)
          }
          if (scenario === 'no-output-synthetic-then-error') {
            yield {
              type: 'result',
              subtype: 'error_during_execution',
              is_error: true,
              errors: ['later fixture provider error'],
              stop_reason: null,
              duration_ms: 50,
              duration_api_ms: 1,
              num_turns: 0,
              total_cost_usd: 0,
              usage: {
                input_tokens: 0,
                cache_creation_input_tokens: 0,
                cache_read_input_tokens: 0,
                output_tokens: 0,
              },
              modelUsage: {},
              permission_denials: [],
              uuid: 'later-error-result-' + attempt,
              session_id: responseSession,
            }
          }
          return
        }

        if (scenario === 'side-effect' || scenario === 'system-side-effect') {
          record('tool-effect-once')
          if (scenario === 'system-side-effect') {
            yield {
              type: 'system',
              subtype: 'task_started',
              task_id: 'background-side-effect',
              tool_use_id: 'tool-1',
              description: 'fixture task already started',
              session_id: 'overfull-session',
            }
          } else {
            yield {
              type: 'assistant',
              session_id: 'overfull-session',
              uuid: 'tool-frame',
              parent_tool_use_id: null,
              message: {
                model: 'claude-fixture',
                content: [{
                  type: 'tool_use',
                  id: 'tool-1',
                  name: 'Read',
                  input: { file_path: '/tmp/example' },
                }],
                usage: {
                  input_tokens: 190000,
                  cache_creation_input_tokens: 0,
                  cache_read_input_tokens: 0,
                  output_tokens: 5,
                },
              },
            }
          }
        }

        // Issue 47's real shape: a first message whose Skill load inflates the turn past the
        // window. The generic compaction-failure block below then fires for attempt 1.
        if (scenario === 'first-message-skill') {
          yield {
            type: 'assistant',
            session_id: responseSession,
            uuid: 'skill-frame',
            parent_tool_use_id: null,
            message: {
              model: 'claude-fixture',
              content: [{
                type: 'tool_use',
                id: 'skill-1',
                name: 'Skill',
                input: { skill: 'claude-api' },
              }],
              usage: {
                input_tokens: 190000,
                cache_creation_input_tokens: 0,
                cache_read_input_tokens: 0,
                output_tokens: 5,
              },
            },
          }
        }

        if (scenario === 'hook-side-effect') {
          record('prompt-hook-effect-once')
          yield {
            type: 'system',
            subtype: 'hook_started',
            hook_id: 'prompt-hook',
            hook_name: 'fixture prompt hook',
            hook_event: 'UserPromptSubmit',
            session_id: 'overfull-session',
          }
        }

        // The 2026-08-14 field incident: a resumed turn whose first provider event is a background
        // task_notification, acknowledged by the SDK with an immediate zero-API result BEFORE the
        // model runs. The real answer then arrives in a second cycle. agentd must count that answer.
        if (scenario === 'result-then-real-answer') {
          yield {
            type: 'system',
            subtype: 'task_notification',
            task_id: 'background-measurement',
            tool_use_id: 'tool-earlier-turn',
            session_id: responseSession,
          }
          yield {
            type: 'result',
            subtype: 'success',
            is_error: false,
            result: 'No response requested.',
            stop_reason: 'stop_sequence',
            duration_ms: 68,
            duration_api_ms: 0,
            num_turns: 0,
            // Deliberately NOT the exact synthetic shape: a nonzero cost is exactly what
            // isClaudeSyntheticNoOutputResult refuses, so the watchdog stops here for real.
            total_cost_usd: 0.01,
            usage: {
              input_tokens: 0,
              cache_creation_input_tokens: 0,
              cache_read_input_tokens: 0,
              output_tokens: 0,
            },
            modelUsage: {},
            permission_denials: [],
            uuid: 'notification-close-' + attempt,
            session_id: responseSession,
          }
        }

        if ((attempt === 1 && scenario !== 'vertex-usage-hangs'
              && scenario !== 'vertex-turn-rapt' && !cacheScenario
              && scenario !== 'result-then-real-answer')
            || scenario === 'repeat') {
          yield {
            type: 'system',
            subtype: 'status',
            status: 'compacting',
            session_id: responseSession,
          }
          yield {
            type: 'system',
            subtype: 'status',
            status: null,
            compact_result: 'failed',
            compact_error: 'too_few_groups',
            session_id: responseSession,
          }
          // Advancing the failed iterator to this point reproduces the old bug: the CLI would now
          // submit the unchanged oversized request to Vertex. agentd must throw at the status above.
          record('VERTEX_REQUEST_SUBMITTED_AFTER_FAILED_COMPACTION')
          yield {
            type: 'result',
            subtype: 'error_during_execution',
            is_error: true,
            terminal_reason: 'prompt_too_long',
            errors: ['Prompt is too long: blocking_limit'],
            session_id: attempt === 1 ? 'overfull-session' : 'fresh-session',
            modelUsage: {},
          }
          return
        }

        yield {
          type: 'stream_event',
          session_id: responseSession,
          uuid: 'fresh-frame',
          event: {
            type: 'content_block_delta',
            delta: { type: 'text_delta', text: 'recovered response' },
          },
        }
        if (cacheScenario && scenario !== 'cache-no-assistant-sample') {
          const sampleInput = scenario === 'cache-near-limit'
            ? Math.floor(responseContextWindow * 0.85)
            : 18000
          yield {
            type: 'assistant',
            session_id: assistantSession,
            uuid: 'cache-frame-' + attempt,
            parent_tool_use_id: null,
            message: {
              id: 'cache-message-' + attempt,
              model: responseModel,
              role: 'assistant',
              content: [{ type: 'text', text: 'recovered response' }],
              stop_reason: 'end_turn',
              stop_sequence: null,
              usage: {
                input_tokens: sampleInput,
                cache_creation_input_tokens: 0,
                cache_read_input_tokens: 0,
                output_tokens: 50,
              },
            },
          }
        }
        if (scenario === 'cache-stale-assistant') {
          yield {
            type: 'assistant',
            session_id: responseSession,
            uuid: 'synthetic-frame-' + attempt,
            parent_tool_use_id: null,
            message: {
              id: 'synthetic-message-' + attempt,
              model: responseModel,
              role: 'assistant',
              content: [],
              stop_reason: null,
              stop_sequence: null,
            },
          }
        }
        if (scenario === 'cache-stale-user') {
          yield {
            type: 'user',
            session_id: responseSession,
            uuid: 'synthetic-user-frame-' + attempt,
            parent_tool_use_id: null,
            message: {
              role: 'user',
              content: [{ type: 'text', text: 'synthetic trailing context' }],
            },
          }
        }
        if (scenario === 'cache-commands-changed') {
          yield {
            type: 'system',
            subtype: 'commands_changed',
            session_id: responseSession,
            commands: [{ name: 'new-command', description: 'new dynamic command' }],
          }
        }
        if (scenario === 'cache-compacted') {
          const postCompact = options?.hooks?.PostCompact?.[0]?.hooks?.[0]
          if (typeof postCompact === 'function') {
            await postCompact({
              hook_event_name: 'PostCompact',
              trigger: 'auto',
              compact_summary: 'Keep the complete transcript and continue from this summary.',
              session_id: responseSession,
              prompt_id: 'prompt-cache-compacted',
            })
          }
          yield {
            type: 'system',
            subtype: 'compact_boundary',
            session_id: responseSession,
            compact_metadata: { trigger: 'auto', pre_tokens: 170000, post_tokens: 18000 },
          }
        }
        if (scenario === 'cache-conversation-reset' && attempt === 2) {
          yield {
            type: 'conversation_reset',
            uuid: 'reset-frame-' + attempt,
            session_id: responseSession,
            new_conversation_id: terminalSession,
          }
        }
        if (scenario === 'prompt-suggestion') {
          record(JSON.stringify({ kind: 'sdk-result' }))
        }
        yield {
          type: 'result',
          subtype: 'success',
          is_error: false,
          result: 'recovered response',
          session_id: resultSession,
          modelUsage: {
            [resultModelKey]: {
              inputTokens: 18000,
              cacheReadInputTokens: 0,
              cacheCreationInputTokens: 0,
              contextWindow: responseContextWindow,
              canonicalModel: responseModel,
            },
          },
        }
        if (scenario === 'prompt-suggestion') {
          const suggestion = ${JSON.stringify(providerPromptSuggestion)}
          record(JSON.stringify({ kind: 'sdk-prompt-suggestion', suggestion }))
          yield {
            type: 'prompt_suggestion',
            suggestion,
            session_id: resultSession,
          }
        }
      })()
      const catalogEntry = {
        value: requestedModel,
        resolvedModel: fableScenario ? responseModel : responseContextModel,
      }
      if (!initializationMissing) {
        stream.initializationResult = async () => ({
          models: catalogMissing
            ? []
            : catalogDuplicated ? [catalogEntry, { ...catalogEntry }] : [catalogEntry],
        })
      }
      stream.supportedCommands = async () => []
      stream.getContextUsage = async () => {
        record(JSON.stringify({ kind: 'context-usage', attempt }))
        if (scenario === 'cache-steer-before-root') {
          while (!fs.existsSync(capture + '.release-preflight')) {
            await new Promise((resolve) => setTimeout(resolve, 5))
          }
        }
        if (scenario === 'usage-hangs' || scenario === 'vertex-usage-hangs') {
          return new Promise(() => {})
        }
        return {
          categories: [],
          totalTokens: options?.resume ? 178000 : 12000,
          maxTokens: responseContextWindow,
          rawMaxTokens: responseContextWindow,
          percentage: options?.resume ? 89 : 6,
          gridRows: [],
          model: baselineAliasEcho ? requestedModel : responseContextModel,
          memoryFiles: [],
          mcpTools: [],
          autoCompactThreshold: aliasScenario ? 967000 : 160000,
          isAutoCompactEnabled: autoCompactEnabled,
        }
      }
      stream.applyFlagSettings = async (settings) => {
        record(JSON.stringify({ kind: 'apply-settings', attempt, settings }))
        if (scenario === 'apply-hangs') return new Promise(() => {})
        autoCompactEnabled = settings?.autoCompactEnabled === true
      }
      return stream
    }
  `
  const sdkURL = `data:text/javascript;base64,${Buffer.from(sdkSource).toString('base64')}`
  fs.writeFileSync(path.join(directory, 'hooks.mjs'), `
    const sdkURL = ${JSON.stringify(sdkURL)}
    export async function resolve(specifier, context, nextResolve) {
      if (specifier === '@anthropic-ai/claude-agent-sdk') {
        return { url: sdkURL, shortCircuit: true }
      }
      // This fixture exercises the Claude stream only. Keep it independent of optional sibling
      // recovery modules that another workstream may be adding to the daemon concurrently.
      if (specifier === './mcp-oauth-errors.mjs'
          && context.parentURL?.endsWith('/agentd/src/agentd.mjs')) {
        const source = 'export function mcpOAuthFailurePayload() { return {} }'
        return {
          url: 'data:text/javascript;base64,' + Buffer.from(source).toString('base64'),
          shortCircuit: true,
        }
      }
      if (specifier === './vertex-adc.mjs'
          && context.parentURL?.endsWith('/agentd/src/agentd.mjs')) {
        const source = \`
          let turnPreflightCount = 0
          export function createVertexAdc() {
            return {
              hasCredentials() { return true },
              async refreshTokens(reason) {
                if (process.env.MECHANICIAN_CONTEXT_FIXTURE === 'vertex-turn-rapt'
                    && reason === 'turn-preflight'
                    && ++turnPreflightCount === 1) {
                  return {
                    ok: false,
                    reason: 'reauth_required',
                    errorSubtype: 'invalid_rapt',
                    httpStatus: 400,
                  }
                }
                return {
                  ok: true,
                  tokens: { access_token: 'vertex-fixture', expires_in: 3600 },
                }
              },
              async checkAuth() {
                if (process.env.MECHANICIAN_CONTEXT_FIXTURE === 'vertex-rapt-ready') {
                  return {
                    authenticated: false,
                    reason: 'reauth_required',
                    errorSubtype: 'invalid_rapt',
                    httpStatus: 400,
                  }
                }
                return { authenticated: true, email: 'fixture@example.test' }
              },
            }
          }
          export function resolveVertexAuthState(status, hasCredentials = false) {
            if (status?.authenticated === true) {
              return { loggedIn: true, verification: 'verified', reason: null }
            }
            const reason = status?.reason || 'unknown'
            const disconnected = !hasCredentials
              || ['no_credentials', 'revoked', 'reauth_required'].includes(reason)
            return {
              loggedIn: !disconnected,
              verification: disconnected ? 'disconnected' : 'deferred',
              reason,
            }
          }
        \`
        return {
          url: 'data:text/javascript;base64,' + Buffer.from(source).toString('base64'),
          shortCircuit: true,
        }
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

function startFixture(t, scenario, {
  authMode = 'apikey',
  contextControlTimeoutMs = 100,
  firstResponseTimeoutMs = '',
  firstRealOutputTimeoutMs = '',
} = {}) {
  const support = fs.mkdtempSync(path.join(os.tmpdir(), 'mechanician-context-recovery-'))
  const capture = path.join(support, 'sdk-events.txt')
  const loader = writeSDKLoader(support, capture)
  const child = spawn(process.execPath, ['--import', loader, agentd], {
    env: {
      ...process.env,
      MECHANICIAN_PROVIDER: 'anthropic',
      MECHANICIAN_AUTH: authMode,
      MECHANICIAN_CONFIG_DIR: support,
      MECHANICIAN_CWD: support,
      MECHANICIAN_CONTEXT_FIXTURE: scenario,
      MECHANICIAN_CLAUDE_CONTEXT_CONTROL_TIMEOUT_MS: String(contextControlTimeoutMs),
      MECHANICIAN_TEST_PROVIDER_FIRST_RESPONSE_TIMEOUT_MS: String(firstResponseTimeoutMs),
      MECHANICIAN_TEST_PROVIDER_FIRST_REAL_OUTPUT_TIMEOUT_MS: String(firstRealOutputTimeoutMs),
      MECHANICIAN_VERTEX_PROJECT: authMode === 'vertex' ? 'fixture-project' : '',
      MECHANICIAN_VERTEX_REGION: authMode === 'vertex' ? 'global' : '',
      MECHANICIAN_MANAGED_MODEL: authMode === 'vertex' ? 'claude-opus-4-8' : '',
      ANTHROPIC_API_KEY: authMode === 'apikey' ? 'fixture-api-key' : '',
      ANTHROPIC_AUTH_TOKEN: '',
      CLAUDE_CODE_OAUTH_TOKEN: authMode === 'subscription' ? 'fixture-oauth-token' : '',
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
  const fixture = {
    child,
    events,
    capture,
    get stderr() { return stderr },
    records() {
      if (!fs.existsSync(capture)) return []
      return fs.readFileSync(capture, 'utf8').trim().split('\n').filter(Boolean)
    },
  }
  t.after(async () => {
    if (child.exitCode === null) child.kill('SIGKILL')
    if (child.exitCode === null) {
      try { await once(child, 'exit') } catch {}
    }
    fs.rmSync(support, { recursive: true, force: true })
  })
  return fixture
}

function sendOverfullTurn(fixture, id = 'turn-context') {
  const hugeOldEntry = `old-start-${'x'.repeat(180_000)}-old-end`
  fixture.child.stdin.write(`${JSON.stringify({
    type: 'send',
    id,
    convId: 'conversation-context',
    sessionId: 'overfull-session',
    cwd: path.dirname(fixture.capture),
    prompt: 'answer this exact current prompt',
    history: [
      { role: 'user', text: hugeOldEntry },
      { role: 'assistant', text: 'newest assistant fact' },
      { role: 'user', text: 'answer this exact current prompt' },
    ],
  })}\n`)
}

function sendSmallRecoverableTurn(
  fixture,
  id = 'turn-small-recovery',
  { sessionId = 'overfull-session' } = {},
) {
  fixture.child.stdin.write(`${JSON.stringify({
    type: 'send',
    id,
    convId: 'conversation-small-recovery',
    sessionId,
    cwd: path.dirname(fixture.capture),
    prompt: 'answer this exact current prompt',
    history: [
      { role: 'user', text: 'older user fact' },
      { role: 'assistant', text: 'newest assistant fact' },
      { role: 'user', text: 'answer this exact current prompt' },
    ],
  })}\n`)
}

// A brand-new conversation's FIRST message, shaped the way AgentBridge actually sends one: no
// session to resume, and a history holding only the prompt itself. That one entry is what makes
// `priorHistory` empty, which is what makes every retry byte-identical.
function sendFirstMessageTurn(fixture, id = 'turn-first-message') {
  fixture.child.stdin.write(`${JSON.stringify({
    type: 'send',
    id,
    convId: 'conversation-first-message',
    sessionId: null,
    cwd: path.dirname(fixture.capture),
    prompt: 'answer this exact current prompt',
    history: [{ role: 'user', text: 'answer this exact current prompt' }],
  })}\n`)
}

function sendHugeFreshTurn(fixture, id = 'turn-huge-fresh') {
  fixture.child.stdin.write(`${JSON.stringify({
    type: 'send',
    id,
    convId: 'conversation-huge-fresh',
    sessionId: null,
    cwd: path.dirname(fixture.capture),
    prompt: `exact-current-start-${'p'.repeat(500_000)}-exact-current-end`,
    history: [],
  })}\n`)
}

function sendDualPromptTurn(fixture, id, {
  sessionId,
  prompt,
  freshPrompt,
}) {
  fixture.child.stdin.write(`${JSON.stringify({
    type: 'send',
    id,
    convId: 'conversation-dual-prompt',
    sessionId,
    cwd: path.dirname(fixture.capture),
    prompt,
    freshPrompt,
    history: [{ role: 'user', text: prompt }],
  })}\n`)
}

function sendCacheTurn(
  fixture,
  id,
  {
    sessionId = null,
    convId = 'conversation-cache',
    projectInstructions = 'fixture instructions',
    prompt = 'small cacheable follow-up',
    model = undefined,
  } = {},
) {
  fixture.child.stdin.write(`${JSON.stringify({
    type: 'send',
    id,
    convId,
    sessionId,
    cwd: path.dirname(fixture.capture),
    projectInstructions,
    prompt,
    model,
    history: [{ role: 'user', text: prompt }],
  })}\n`)
}

function structuredRecords(fixture) {
  return fixture.records().filter((line) => line.startsWith('{')).map(JSON.parse)
}

test('ordinary Claude forwards its post-result prompt suggestion unchanged before done', async (t) => {
  const fixture = startFixture(t, 'prompt-suggestion')
  await waitFor(() => fixture.events.find((event) => event.type === 'ready'), 'ready', fixture)
  sendCacheTurn(fixture, 'turn-prompt-suggestion')

  const terminal = await waitFor(
    () => fixture.events.find((event) => event.id === 'turn-prompt-suggestion'
      && (event.type === 'done' || event.type === 'error')),
    'prompt-suggestion terminal',
    fixture,
  )
  assert.deepEqual(terminal, { type: 'done', id: 'turn-prompt-suggestion' })

  const records = structuredRecords(fixture)
  assert.equal(records.find((entry) => entry.kind === 'query')?.promptSuggestions, true)
  const sdkResultIndex = records.findIndex((entry) => entry.kind === 'sdk-result')
  const sdkSuggestionIndex = records.findIndex(
    (entry) => entry.kind === 'sdk-prompt-suggestion')
  assert.ok(sdkResultIndex >= 0, 'the fixture must emit an SDK result')
  assert.ok(
    sdkSuggestionIndex > sdkResultIndex,
    'the fixture suggestion must follow the SDK result',
  )

  const suggestionIndex = fixture.events.findIndex((event) =>
    event.type === 'prompt_suggestion' && event.id === 'turn-prompt-suggestion')
  const terminalIndex = fixture.events.indexOf(terminal)
  assert.ok(suggestionIndex >= 0 && suggestionIndex < terminalIndex)
  assert.deepEqual(fixture.events[suggestionIndex], {
    type: 'prompt_suggestion',
    id: 'turn-prompt-suggestion',
    suggestion: providerPromptSuggestion,
  })
  assert.deepEqual(
    Buffer.from(fixture.events[suggestionIndex].suggestion, 'utf8'),
    Buffer.from(providerPromptSuggestion, 'utf8'),
  )
})

test('a later Claude query keeps background Agent lifecycle on its original turn', async (t) => {
  const fixture = startFixture(t, 'cache-task-owner-across-turns')
  await waitFor(() => fixture.events.find((event) => event.type === 'ready'), 'ready', fixture)

  sendCacheTurn(fixture, 'turn-agent-owner')
  await waitFor(
    () => fixture.events.find((event) => event.id === 'turn-agent-owner'
      && event.type === 'done'),
    'background Agent owner turn terminal',
    fixture,
  )
  sendCacheTurn(fixture, 'turn-agent-observer', { sessionId: 'cache-session' })
  await waitFor(
    () => fixture.events.find((event) => event.id === 'turn-agent-observer'
      && event.type === 'done'),
    'background Agent observer turn terminal',
    fixture,
  )

  const agentLifecycle = fixture.events.filter((event) =>
    event.type === 'workflow_update' && event.taskId === 'background-agent')
  assert.ok(agentLifecycle.some((event) => event.phase === 'started'))
  assert.ok(agentLifecycle.some((event) => event.phase === 'notification'
    && event.status === 'completed'))
  assert.ok(agentLifecycle.some((event) => event.phase === 'progress'
    && event.summary === 'Found the fixture'))
  assert.ok(agentLifecycle.every((event) => event.id === 'turn-agent-owner'),
    'child work observed by the next query remains on the launching Mechanician turn')
  assert.equal(agentLifecycle.filter((event) => event.phase === 'notification').length, 1,
    'terminal replay cannot publish a second lifecycle boundary')
  assert.equal(agentLifecycle.some((event) => event.summary === 'duplicate progress'), false)
  const cancelledLifecycle = fixture.events.filter((event) =>
    event.type === 'workflow_update' && event.taskId === 'cancelled-agent')
  assert.ok(cancelledLifecycle.every((event) => event.id === 'turn-agent-owner'))
  assert.ok(cancelledLifecycle.some((event) =>
    event.phase === 'updated' && event.status === 'stopped'),
  'the SDK cancellation spelling is normalized to Swift\'s terminal status vocabulary')
  assert.equal(fixture.events.some((event) =>
    event.type === 'workflow_update' && event.taskId === 'background-bash'), false,
  'unknown background Bash remains outside the Agent lifecycle')

  assert.equal(fixture.events.find((event) =>
    event.type === 'tool_use' && event.toolUseId === 'late-child-read')?.id,
  'turn-agent-owner')
  assert.equal(fixture.events.find((event) =>
    event.type === 'tool_result' && event.toolUseId === 'late-child-read')?.id,
  'turn-agent-owner')
  assert.equal(fixture.events.find((event) =>
    event.type === 'usage' && event.agentToolUseId === 'tool-background-agent'
      && event.output === 3)?.id,
  'turn-agent-owner')
  assert.ok(fixture.events.some((event) => event.type === 'delta'
    && event.id === 'turn-agent-observer' && event.text === 'recovered response'),
  'the second query root output stays on its own turn')
})

test('Claude routes a split-query child tool result to its original owner turn', async (t) => {
  const fixture = startFixture(t, 'cache-task-split-child-result')
  await waitFor(() => fixture.events.find((event) => event.type === 'ready'), 'ready', fixture)

  sendCacheTurn(fixture, 'turn-split-result-owner')
  await waitFor(() => fixture.events.find((event) =>
    event.id === 'turn-split-result-owner' && event.type === 'done'),
  'split-result owner turn', fixture)
  sendCacheTurn(fixture, 'turn-split-result-successor', { sessionId: 'cache-session' })
  await waitFor(() => fixture.events.find((event) =>
    event.id === 'turn-split-result-successor' && event.type === 'done'),
  'split-result successor turn', fixture)

  assert.equal(fixture.events.find((event) =>
    event.type === 'tool_use' && event.toolUseId === 'split-query-child-read')?.id,
  'turn-split-result-owner')
  const splitResults = fixture.events.filter((event) =>
    event.type === 'tool_result' && event.toolUseId === 'split-query-child-read')
  assert.equal(splitResults.length, 1)
  assert.equal(splitResults[0].id, 'turn-split-result-owner',
    'the next query resolves a parentless result through the provider-session child-tool alias')
  assert.equal(fixture.events.some((event) =>
    event.id === 'turn-split-result-successor'
      && ((event.type === 'tool_use' && event.toolUseId === 'split-query-child-read')
        || (event.type === 'tool_result' && event.toolUseId === 'split-query-child-read'))), false,
  'the successor transcript receives none of the earlier child tool pair')
  assert.ok(fixture.events.some((event) => event.type === 'delta'
    && event.id === 'turn-split-result-successor' && event.text === 'recovered response'))
})

test('Claude keeps terminal-tail child tools, usage, and nested Agent work on the owner turn', async (t) => {
  const fixture = startFixture(t, 'cache-task-terminal-tail')
  await waitFor(() => fixture.events.find((event) => event.type === 'ready'), 'ready', fixture)

  sendCacheTurn(fixture, 'turn-terminal-tail-owner')
  await waitFor(
    () => fixture.events.find((event) => event.id === 'turn-terminal-tail-owner'
      && event.type === 'done'),
    'terminal-tail owner turn',
    fixture,
  )
  sendCacheTurn(fixture, 'turn-terminal-tail-observer', { sessionId: 'cache-session' })
  await waitFor(
    () => fixture.events.find((event) => event.id === 'turn-terminal-tail-observer'
      && event.type === 'done'),
    'terminal-tail observer turn',
    fixture,
  )

  const tailToolIds = new Set(['terminal-tail-read', 'terminal-tail-nested-agent'])
  const tailTools = fixture.events.filter((event) =>
    event.type === 'tool_use' && tailToolIds.has(event.toolUseId))
  assert.equal(tailTools.length, 2)
  assert.ok(tailTools.every((event) => event.id === 'turn-terminal-tail-owner'))
  assert.equal(fixture.events.find((event) =>
    event.type === 'tool_result' && event.toolUseId === 'terminal-tail-read')?.id,
  'turn-terminal-tail-owner')
  assert.equal(fixture.events.find((event) =>
    event.type === 'usage' && event.agentToolUseId === 'tool-background-agent'
      && event.output === 7)?.id,
  'turn-terminal-tail-owner')
  const nestedLifecycle = fixture.events.filter((event) =>
    event.type === 'workflow_update' && event.taskId === 'terminal-tail-nested-task')
  assert.deepEqual(nestedLifecycle.map((event) => event.phase), ['started', 'notification'])
  assert.ok(nestedLifecycle.every((event) => event.id === 'turn-terminal-tail-owner'),
    'a nested Agent launched after parent terminal inherits the parent owner')
  assert.ok(fixture.events.some((event) => event.type === 'delta'
    && event.id === 'turn-terminal-tail-observer' && event.text === 'recovered response'))
  assert.equal(fixture.events.some((event) => event.id === 'turn-terminal-tail-observer'
    && ((event.type === 'tool_use' && tailToolIds.has(event.toolUseId))
      || (event.type === 'tool_result' && event.toolUseId === 'terminal-tail-read'))), false,
  'terminal-tail child details never enter the later turn transcript')
})

test('Claude routes a child frame delayed until the query after terminal to its owner turn', async (t) => {
  const fixture = startFixture(t, 'cache-task-terminal-tail-next-query')
  await waitFor(() => fixture.events.find((event) => event.type === 'ready'), 'ready', fixture)

  sendCacheTurn(fixture, 'turn-delayed-tail-owner')
  await waitFor(() => fixture.events.find((event) =>
    event.id === 'turn-delayed-tail-owner' && event.type === 'done'),
  'delayed-tail owner turn', fixture)
  sendCacheTurn(fixture, 'turn-delayed-tail-terminal', { sessionId: 'cache-session' })
  await waitFor(() => fixture.events.find((event) =>
    event.id === 'turn-delayed-tail-terminal' && event.type === 'done'),
  'delayed-tail terminal turn', fixture)
  sendCacheTurn(fixture, 'turn-delayed-tail-observer', { sessionId: 'cache-session' })
  await waitFor(() => fixture.events.find((event) =>
    event.id === 'turn-delayed-tail-observer' && event.type === 'done'),
  'delayed-tail observer turn', fixture)

  for (const event of fixture.events.filter((candidate) =>
    (candidate.type === 'tool_use' && candidate.toolUseId === 'next-query-tail-read')
      || (candidate.type === 'tool_result' && candidate.toolUseId === 'next-query-tail-read')
      || (candidate.type === 'usage' && candidate.agentToolUseId === 'tool-background-agent'
        && candidate.output === 8))) {
    assert.equal(event.id, 'turn-delayed-tail-owner')
  }
  assert.equal(fixture.events.filter((event) =>
    event.type === 'tool_use' && event.toolUseId === 'next-query-tail-read').length, 1)
  assert.equal(fixture.events.filter((event) =>
    event.type === 'tool_result' && event.toolUseId === 'next-query-tail-read').length, 1)
  assert.ok(fixture.events.some((event) => event.type === 'delta'
    && event.id === 'turn-delayed-tail-observer' && event.text === 'recovered response'))
})

test('a Claude session reset stops retained Agent work on its original turn', async (t) => {
  const fixture = startFixture(t, 'cache-task-session-reset')
  await waitFor(() => fixture.events.find((event) => event.type === 'ready'), 'ready', fixture)

  sendCacheTurn(fixture, 'turn-agent-before-reset')
  await waitFor(
    () => fixture.events.find((event) => event.id === 'turn-agent-before-reset'
      && event.type === 'done'),
    'pre-reset Agent owner terminal',
    fixture,
  )
  sendCacheTurn(fixture, 'turn-reset-session', { sessionId: 'cache-session' })
  await waitFor(
    () => fixture.events.find((event) => event.id === 'turn-reset-session'
      && event.type === 'done'),
    'session reset terminal',
    fixture,
  )

  assert.ok(fixture.events.some((event) =>
    event.type === 'workflow_update'
      && event.id === 'turn-agent-before-reset'
      && event.taskId === 'background-agent'
      && event.phase === 'notification'
      && event.status === 'stopped'),
  'retiring a session closes its live Agent card instead of silently losing owner evidence')
  assert.equal(fixture.events.some((event) =>
    event.type === 'workflow_update' && event.taskId === 'background-bash'), false)
  assert.equal(fixture.events.some((event) =>
    event.type === 'workflow_update' && event.summary === 'late retired-session replay'), false,
  'a late frame from the retired provider session cannot reopen the stopped card')
  assert.equal(fixture.events.find((event) =>
    event.type === 'tool_use' && event.toolUseId === 'retired-session-tail-read')?.id,
  'turn-agent-before-reset')
  assert.equal(fixture.events.find((event) =>
    event.type === 'tool_result' && event.toolUseId === 'retired-session-tail-read')?.id,
  'turn-agent-before-reset')
  assert.equal(fixture.events.find((event) =>
    event.type === 'usage' && event.agentToolUseId === 'tool-background-agent'
      && event.output === 9)?.id,
  'turn-agent-before-reset')
  assert.ok(fixture.events.some((event) => event.type === 'delta'
    && event.id === 'turn-reset-session' && event.text === 'reset response'))
  assert.deepEqual(fixture.events.filter((event) =>
    event.type === 'session' && event.id === 'turn-reset-session')
    .map((event) => event.sessionId), ['cache-session-next'])
})

test('an unexplained Claude session change stops retained Agent work before adoption', async (t) => {
  const fixture = startFixture(t, 'cache-task-session-mismatch')
  await waitFor(() => fixture.events.find((event) => event.type === 'ready'), 'ready', fixture)

  sendCacheTurn(fixture, 'turn-agent-before-mismatch')
  await waitFor(
    () => fixture.events.find((event) => event.id === 'turn-agent-before-mismatch'
      && event.type === 'done'),
    'pre-mismatch Agent owner terminal',
    fixture,
  )
  sendCacheTurn(fixture, 'turn-session-mismatch', { sessionId: 'cache-session' })
  await waitFor(
    () => fixture.events.find((event) => event.id === 'turn-session-mismatch'
      && event.type === 'done'),
    'session mismatch terminal',
    fixture,
  )

  assert.ok(fixture.events.some((event) =>
    event.type === 'workflow_update'
      && event.id === 'turn-agent-before-mismatch'
      && event.taskId === 'background-agent'
      && event.phase === 'notification'
      && event.status === 'stopped'),
  'the old session is drained before the replacement session becomes durable')
  assert.equal(fixture.events.some((event) =>
    event.type === 'workflow_update' && event.taskId === 'background-bash'), false)
  assert.equal(fixture.events.find((event) =>
    event.type === 'tool_use' && event.toolUseId === 'mismatched-session-tail-read')?.id,
  'turn-agent-before-mismatch')
  assert.equal(fixture.events.find((event) =>
    event.type === 'tool_result' && event.toolUseId === 'mismatched-session-tail-read')?.id,
  'turn-agent-before-mismatch')
  assert.equal(fixture.events.find((event) =>
    event.type === 'usage' && event.agentToolUseId === 'tool-background-agent'
      && event.output === 10)?.id,
  'turn-agent-before-mismatch')
  assert.ok(fixture.events.some((event) => event.type === 'delta'
    && event.id === 'turn-session-mismatch' && event.text === 'mismatch response'))
  assert.ok(fixture.events.some((event) => event.type === 'session'
    && event.id === 'turn-session-mismatch'
    && event.sessionId === 'cache-session-next'))
})

test('a safe terminal usage sample skips context control on the next exact continuation', async (t) => {
  const fixture = startFixture(t, 'cache-safe')
  await waitFor(() => fixture.events.find((event) => event.type === 'ready'), 'ready', fixture)
  sendCacheTurn(fixture, 'turn-cache-seed')
  assert.deepEqual(await waitFor(
    () => fixture.events.find((event) => event.id === 'turn-cache-seed'
      && (event.type === 'done' || event.type === 'error')),
    'cache seed terminal',
    fixture,
  ), { type: 'done', id: 'turn-cache-seed' })

  sendCacheTurn(fixture, 'turn-cache-hit', { sessionId: 'cache-session' })
  assert.deepEqual(await waitFor(
    () => fixture.events.find((event) => event.id === 'turn-cache-hit'
      && (event.type === 'done' || event.type === 'error')),
    'cached continuation terminal',
    fixture,
  ), { type: 'done', id: 'turn-cache-hit' })

  sendCacheTurn(fixture, 'turn-cache-chain', { sessionId: 'cache-session' })
  assert.deepEqual(await waitFor(
    () => fixture.events.find((event) => event.id === 'turn-cache-chain'
      && (event.type === 'done' || event.type === 'error')),
    'chained cached continuation terminal',
    fixture,
  ), { type: 'done', id: 'turn-cache-chain' })

  const records = structuredRecords(fixture)
  assert.deepEqual(
    records.filter((entry) => entry.kind === 'query').map((entry) => entry.resume),
    [null, 'cache-session', 'cache-session'],
  )
  assert.deepEqual(
    records.filter((entry) => entry.kind === 'context-usage').map((entry) => entry.attempt),
    [1],
    'the resumed turn uses the prior terminal sample without a blocking SDK control',
  )
  assert.match(fixture.stderr, /\[context\]\[cache\] store=stored/)
  assert.equal((fixture.stderr.match(/\[context\]\[cache\] claim=hit/g) || []).length, 2)
  assert.match(fixture.stderr, /Claude cached usage accepted/)
})

test('a near-limit cached sample falls back to authoritative context control', async (t) => {
  const fixture = startFixture(t, 'cache-near-limit')
  await waitFor(() => fixture.events.find((event) => event.type === 'ready'), 'ready', fixture)
  sendCacheTurn(fixture, 'turn-cache-near-seed')
  await waitFor(
    () => fixture.events.find((event) => event.id === 'turn-cache-near-seed'
      && event.type === 'done'),
    'near-limit cache seed terminal',
    fixture,
  )

  sendCacheTurn(fixture, 'turn-cache-near-control', { sessionId: 'cache-session' })
  assert.deepEqual(await waitFor(
    () => fixture.events.find((event) => event.id === 'turn-cache-near-control'
      && (event.type === 'done' || event.type === 'error')),
    'near-limit authoritative terminal',
    fixture,
  ), { type: 'done', id: 'turn-cache-near-control' })

  assert.deepEqual(
    structuredRecords(fixture)
      .filter((entry) => entry.kind === 'context-usage').map((entry) => entry.attempt),
    [1, 2],
  )
  assert.match(fixture.stderr, /cached usage rejected reason=near_limit/)
})

test('a changed query configuration consumes the sample and uses authoritative control', async (t) => {
  const fixture = startFixture(t, 'cache-safe')
  await waitFor(() => fixture.events.find((event) => event.type === 'ready'), 'ready', fixture)
  sendCacheTurn(fixture, 'turn-cache-config-seed')
  await waitFor(
    () => fixture.events.find((event) => event.id === 'turn-cache-config-seed'
      && event.type === 'done'),
    'configuration cache seed terminal',
    fixture,
  )

  sendCacheTurn(fixture, 'turn-cache-config-change', {
    sessionId: 'cache-session',
    projectInstructions: 'different fixture instructions',
  })
  assert.deepEqual(await waitFor(
    () => fixture.events.find((event) => event.id === 'turn-cache-config-change'
      && (event.type === 'done' || event.type === 'error')),
    'changed configuration terminal',
    fixture,
  ), { type: 'done', id: 'turn-cache-config-change' })

  assert.deepEqual(
    structuredRecords(fixture)
      .filter((entry) => entry.kind === 'context-usage').map((entry) => entry.attempt),
    [1, 2],
  )
})

test('aggregate result usage alone never seeds the context fast path', async (t) => {
  const fixture = startFixture(t, 'cache-no-assistant-sample')
  await waitFor(() => fixture.events.find((event) => event.type === 'ready'), 'ready', fixture)
  sendCacheTurn(fixture, 'turn-cache-no-sample-seed')
  await waitFor(
    () => fixture.events.find((event) => event.id === 'turn-cache-no-sample-seed'
      && event.type === 'done'),
    'no-sample seed terminal',
    fixture,
  )

  sendCacheTurn(fixture, 'turn-cache-no-sample-control', { sessionId: 'cache-session' })
  assert.deepEqual(await waitFor(
    () => fixture.events.find((event) => event.id === 'turn-cache-no-sample-control'
      && (event.type === 'done' || event.type === 'error')),
    'no-sample authoritative terminal',
    fixture,
  ), { type: 'done', id: 'turn-cache-no-sample-control' })

  assert.deepEqual(
    structuredRecords(fixture)
      .filter((entry) => entry.kind === 'context-usage').map((entry) => entry.attempt),
    [1, 2],
  )
  assert.match(fixture.stderr, /store=skipped reason=missing_terminal_usage/)
})

test('a turn that compacted requires authoritative context control next time', async (t) => {
  const fixture = startFixture(t, 'cache-compacted')
  await waitFor(() => fixture.events.find((event) => event.type === 'ready'), 'ready', fixture)
  sendCacheTurn(fixture, 'turn-cache-compacted-seed')
  await waitFor(
    () => fixture.events.find((event) => event.id === 'turn-cache-compacted-seed'
      && event.type === 'done'),
    'compacted seed terminal',
    fixture,
  )

  sendCacheTurn(fixture, 'turn-cache-after-compaction', { sessionId: 'cache-session' })
  assert.deepEqual(await waitFor(
    () => fixture.events.find((event) => event.id === 'turn-cache-after-compaction'
      && (event.type === 'done' || event.type === 'error')),
    'post-compaction authoritative terminal',
    fixture,
  ), { type: 'done', id: 'turn-cache-after-compaction' })

  assert.deepEqual(
    structuredRecords(fixture)
      .filter((entry) => entry.kind === 'context-usage').map((entry) => entry.attempt),
    [1, 2],
  )
  assert.deepEqual(
    fixture.events.find((event) => event.type === 'compaction_summary'
      && event.id === 'turn-cache-compacted-seed'),
    {
      type: 'compaction_summary',
      id: 'turn-cache-compacted-seed',
      trigger: 'auto',
      compactionSequence: 1,
      summarySource: 'claude_post_compact',
      summaryTruncated: false,
      summaryBytes: 60,
      sessionId: 'cache-session',
      promptId: 'prompt-cache-compacted',
      summary: 'Keep the complete transcript and continue from this summary.',
    },
  )
  assert.deepEqual(
    fixture.events.find((event) => event.type === 'compact_boundary'
      && event.id === 'turn-cache-compacted-seed'),
    {
      type: 'compact_boundary',
      id: 'turn-cache-compacted-seed',
      trigger: 'auto',
      preTokens: 170000,
      postTokens: 18000,
      compactionSequence: 1,
    },
  )
})

test('a later root assistant without usage invalidates an earlier terminal sample', async (t) => {
  const fixture = startFixture(t, 'cache-stale-assistant')
  await waitFor(() => fixture.events.find((event) => event.type === 'ready'), 'ready', fixture)
  sendCacheTurn(fixture, 'turn-cache-stale-seed')
  await waitFor(
    () => fixture.events.find((event) => event.id === 'turn-cache-stale-seed'
      && event.type === 'done'),
    'stale assistant seed terminal',
    fixture,
  )

  sendCacheTurn(fixture, 'turn-cache-stale-control', { sessionId: 'cache-session' })
  await waitFor(
    () => fixture.events.find((event) => event.id === 'turn-cache-stale-control'
      && (event.type === 'done' || event.type === 'error')),
    'stale assistant authoritative terminal',
    fixture,
  )

  assert.deepEqual(
    structuredRecords(fixture)
      .filter((entry) => entry.kind === 'context-usage').map((entry) => entry.attempt),
    [1, 2],
  )
})

test('a later synthetic root user frame invalidates an earlier terminal sample', async (t) => {
  const fixture = startFixture(t, 'cache-stale-user')
  await waitFor(() => fixture.events.find((event) => event.type === 'ready'), 'ready', fixture)
  sendCacheTurn(fixture, 'turn-cache-user-seed')
  await waitFor(
    () => fixture.events.find((event) => event.id === 'turn-cache-user-seed'
      && event.type === 'done'),
    'synthetic user seed terminal',
    fixture,
  )

  sendCacheTurn(fixture, 'turn-cache-user-control', { sessionId: 'cache-session' })
  await waitFor(
    () => fixture.events.find((event) => event.id === 'turn-cache-user-control'
      && (event.type === 'done' || event.type === 'error')),
    'synthetic user authoritative terminal',
    fixture,
  )
  assert.deepEqual(
    structuredRecords(fixture)
      .filter((entry) => entry.kind === 'context-usage').map((entry) => entry.attempt),
    [1, 2],
  )
})

test('a dynamic command-surface change invalidates the context fast path', async (t) => {
  const fixture = startFixture(t, 'cache-commands-changed')
  await waitFor(() => fixture.events.find((event) => event.type === 'ready'), 'ready', fixture)
  sendCacheTurn(fixture, 'turn-cache-commands-seed')
  await waitFor(
    () => fixture.events.find((event) => event.id === 'turn-cache-commands-seed'
      && event.type === 'done'),
    'commands-changed seed terminal',
    fixture,
  )

  sendCacheTurn(fixture, 'turn-cache-commands-control', { sessionId: 'cache-session' })
  await waitFor(
    () => fixture.events.find((event) => event.id === 'turn-cache-commands-control'
      && (event.type === 'done' || event.type === 'error')),
    'commands-changed authoritative terminal',
    fixture,
  )
  assert.deepEqual(
    structuredRecords(fixture)
      .filter((entry) => entry.kind === 'context-usage').map((entry) => entry.attempt),
    [1, 2],
  )
  assert.match(fixture.stderr, /store=skipped reason=commands_changed/)
})

test('a model alias skips control only after the current SDK resolves the same serving model', async (t) => {
  const fixture = startFixture(t, 'cache-alias')
  await waitFor(() => fixture.events.find((event) => event.type === 'ready'), 'ready', fixture)
  sendCacheTurn(fixture, 'turn-cache-alias-seed', { model: 'opus[1m]' })
  await waitFor(
    () => fixture.events.find((event) => event.id === 'turn-cache-alias-seed'
      && event.type === 'done'),
    'alias seed terminal',
    fixture,
  )

  sendCacheTurn(fixture, 'turn-cache-alias-control', {
    sessionId: 'cache-session',
    model: 'opus[1m]',
  })
  await waitFor(
    () => fixture.events.find((event) => event.id === 'turn-cache-alias-control'
      && (event.type === 'done' || event.type === 'error')),
    'alias authoritative terminal',
    fixture,
  )

  sendCacheTurn(fixture, 'turn-cache-alias-chain', {
    sessionId: 'cache-session',
    model: 'opus[1m]',
  })
  await waitFor(
    () => fixture.events.find((event) => event.id === 'turn-cache-alias-chain'
      && (event.type === 'done' || event.type === 'error')),
    'alias chained terminal',
    fixture,
  )
  assert.deepEqual(
    structuredRecords(fixture)
      .filter((entry) => entry.kind === 'context-usage').map((entry) => entry.attempt),
    [1],
  )
  assert.equal((fixture.stderr.match(/\[context\]\[cache\] claim=hit/g) || []).length, 2)
})

test('a version-looking Fable picker value still uses its current catalog resolution', async (t) => {
  const fixture = startFixture(t, 'cache-fable')
  await waitFor(() => fixture.events.find((event) => event.type === 'ready'), 'ready', fixture)
  sendCacheTurn(fixture, 'turn-cache-fable-seed', { model: 'claude-fable-5[1m]' })
  await waitFor(
    () => fixture.events.find((event) => event.id === 'turn-cache-fable-seed'
      && event.type === 'done'),
    'Fable seed terminal',
    fixture,
  )

  sendCacheTurn(fixture, 'turn-cache-fable-hit', {
    sessionId: 'cache-session',
    model: 'claude-fable-5[1m]',
  })
  await waitFor(
    () => fixture.events.find((event) => event.id === 'turn-cache-fable-hit'
      && (event.type === 'done' || event.type === 'error')),
    'Fable cached terminal',
    fixture,
  )

  assert.deepEqual(
    structuredRecords(fixture)
      .filter((entry) => entry.kind === 'context-usage').map((entry) => entry.attempt),
    [1],
  )
  assert.match(
    fixture.stderr,
    /store=stored turn=turn-cache-fable-seed\b.*model=claude-fable-5\b/,
  )
  assert.match(fixture.stderr, /claim=hit turn=turn-cache-fable-hit\b/)
})

test('cached usage requires exactly one current catalog row for the selected model', async (t) => {
  for (const scenario of [
    'cache-initialization-missing',
    'cache-catalog-missing',
    'cache-catalog-duplicate',
  ]) {
    await t.test(scenario, async (subtest) => {
      const fixture = startFixture(subtest, scenario)
      await waitFor(() => fixture.events.find((event) => event.type === 'ready'), 'ready', fixture)
      sendCacheTurn(fixture, `${scenario}-seed`, { model: 'claude-opus-4-8' })
      await waitFor(
        () => fixture.events.find((event) => event.id === `${scenario}-seed`
          && event.type === 'done'),
        `${scenario} seed terminal`,
        fixture,
      )

      sendCacheTurn(fixture, `${scenario}-resume`, {
        sessionId: 'cache-session',
        model: 'claude-opus-4-8',
      })
      assert.deepEqual(await waitFor(
        () => fixture.events.find((event) => event.id === `${scenario}-resume`
          && (event.type === 'done' || event.type === 'error')),
        `${scenario} resumed terminal`,
        fixture,
      ), { type: 'done', id: `${scenario}-resume` })

      assert.deepEqual(
        structuredRecords(fixture)
          .filter((entry) => entry.kind === 'context-usage').map((entry) => entry.attempt),
        [1, 2],
      )
      assert.match(fixture.stderr, /store=skipped reason=missing_model_resolution/)
      assert.doesNotMatch(fixture.stderr, /\[context\]\[cache\] claim=hit/)
    })
  }
})

test('an alias-shaped context baseline cannot stand in for the resolved serving identity', async (t) => {
  const fixture = startFixture(t, 'cache-alias-baseline-echo')
  await waitFor(() => fixture.events.find((event) => event.type === 'ready'), 'ready', fixture)
  sendCacheTurn(fixture, 'turn-cache-baseline-alias-seed', { model: 'opus[1m]' })
  await waitFor(
    () => fixture.events.find((event) => event.id === 'turn-cache-baseline-alias-seed'
      && event.type === 'done'),
    'alias baseline seed terminal',
    fixture,
  )

  sendCacheTurn(fixture, 'turn-cache-baseline-alias-resume', {
    sessionId: 'cache-session',
    model: 'opus[1m]',
  })
  assert.deepEqual(await waitFor(
    () => fixture.events.find((event) => event.id === 'turn-cache-baseline-alias-resume'
      && (event.type === 'done' || event.type === 'error')),
    'alias baseline resumed terminal',
    fixture,
  ), { type: 'done', id: 'turn-cache-baseline-alias-resume' })

  assert.deepEqual(
    structuredRecords(fixture)
      .filter((entry) => entry.kind === 'context-usage').map((entry) => entry.attempt),
    [1, 2],
  )
  assert.match(fixture.stderr, /store=skipped reason=baseline_model_mismatch/)
  assert.doesNotMatch(fixture.stderr, /\[context\]\[cache\] claim=hit/)
})

test('an unexplained provider session change cannot seed the context fast path', async (t) => {
  const fixture = startFixture(t, 'cache-session-mismatch')
  await waitFor(() => fixture.events.find((event) => event.type === 'ready'), 'ready', fixture)
  sendCacheTurn(fixture, 'turn-cache-session-change-seed')
  await waitFor(
    () => fixture.events.find((event) => event.id === 'turn-cache-session-change-seed'
      && event.type === 'done'),
    'session-change seed terminal',
    fixture,
  )

  sendCacheTurn(fixture, 'turn-cache-session-change', {
    sessionId: 'cache-session',
  })
  await waitFor(
    () => fixture.events.find((event) => event.id === 'turn-cache-session-change'
      && (event.type === 'done' || event.type === 'error')),
    'session-change terminal',
    fixture,
  )

  sendCacheTurn(fixture, 'turn-cache-session-change-control', {
    sessionId: 'cache-session-next',
  })
  await waitFor(
    () => fixture.events.find((event) => event.id === 'turn-cache-session-change-control'
      && (event.type === 'done' || event.type === 'error')),
    'session-change authoritative terminal',
    fixture,
  )

  assert.deepEqual(
    structuredRecords(fixture)
      .filter((entry) => entry.kind === 'context-usage').map((entry) => entry.attempt),
    [1, 3],
  )
  assert.match(fixture.stderr, /claim=hit turn=turn-cache-session-change\b/)
  assert.match(fixture.stderr, /session identity changed within turn=turn-cache-session-change\b/)
  assert.match(
    fixture.stderr,
    /store=skipped reason=session_mismatch turn=turn-cache-session-change\b/,
  )
  assert.match(fixture.stderr, /claim=absent turn=turn-cache-session-change-control\b/)
})

test('an SDK conversation reset cannot seed the context fast path', async (t) => {
  const fixture = startFixture(t, 'cache-conversation-reset')
  await waitFor(() => fixture.events.find((event) => event.type === 'ready'), 'ready', fixture)
  sendCacheTurn(fixture, 'turn-cache-reset-seed')
  await waitFor(
    () => fixture.events.find((event) => event.id === 'turn-cache-reset-seed'
      && event.type === 'done'),
    'conversation-reset seed terminal',
    fixture,
  )

  sendCacheTurn(fixture, 'turn-cache-reset', { sessionId: 'cache-session' })
  await waitFor(
    () => fixture.events.find((event) => event.id === 'turn-cache-reset'
      && (event.type === 'done' || event.type === 'error')),
    'conversation-reset terminal',
    fixture,
  )

  sendCacheTurn(fixture, 'turn-cache-reset-control', { sessionId: 'cache-session-next' })
  await waitFor(
    () => fixture.events.find((event) => event.id === 'turn-cache-reset-control'
      && (event.type === 'done' || event.type === 'error')),
    'conversation-reset authoritative terminal',
    fixture,
  )

  assert.deepEqual(
    structuredRecords(fixture)
      .filter((entry) => entry.kind === 'context-usage').map((entry) => entry.attempt),
    [1, 3],
  )
  assert.match(fixture.stderr, /claim=hit turn=turn-cache-reset\b/)
  assert.match(
    fixture.stderr,
    /store=skipped reason=conversation_reset turn=turn-cache-reset\b/,
  )
  assert.match(fixture.stderr, /claim=absent turn=turn-cache-reset-control\b/)
  assert.deepEqual(
    fixture.events.filter((event) => event.type === 'session'
      && event.id === 'turn-cache-reset').map((event) => event.sessionId),
    ['cache-session-next'],
    'the reset frame cannot write its retired session id back over the declared successor',
  )
})

test('a model alias remap consumes the sample and falls back to authoritative control', async (t) => {
  const fixture = startFixture(t, 'cache-alias-remapped')
  await waitFor(() => fixture.events.find((event) => event.type === 'ready'), 'ready', fixture)
  sendCacheTurn(fixture, 'turn-cache-alias-remap-seed', { model: 'opus[1m]' })
  await waitFor(
    () => fixture.events.find((event) => event.id === 'turn-cache-alias-remap-seed'
      && event.type === 'done'),
    'alias-remap seed terminal',
    fixture,
  )

  sendCacheTurn(fixture, 'turn-cache-alias-remap-control', {
    sessionId: 'cache-session',
    model: 'opus[1m]',
  })
  await waitFor(
    () => fixture.events.find((event) => event.id === 'turn-cache-alias-remap-control'
      && (event.type === 'done' || event.type === 'error')),
    'alias-remap authoritative terminal',
    fixture,
  )

  assert.deepEqual(
    structuredRecords(fixture)
      .filter((entry) => entry.kind === 'context-usage').map((entry) => entry.attempt),
    [1, 2],
  )
  assert.match(fixture.stderr, /claim=model_resolution_changed/)
})

test('concurrent claims cannot reseed a shared provider session', async (t) => {
  const fixture = startFixture(t, 'cache-concurrent')
  await waitFor(() => fixture.events.find((event) => event.type === 'ready'), 'ready', fixture)
  sendCacheTurn(fixture, 'turn-cache-concurrent-seed')
  await waitFor(
    () => fixture.events.find((event) => event.id === 'turn-cache-concurrent-seed'
      && event.type === 'done'),
    'concurrency cache seed terminal',
    fixture,
  )

  sendCacheTurn(fixture, 'turn-cache-concurrent-first', { sessionId: 'cache-session' })
  await waitFor(
    () => structuredRecords(fixture)
      .some((entry) => entry.kind === 'prompt' && entry.attempt === 2),
    'first concurrent prompt hold',
    fixture,
  )
  sendCacheTurn(fixture, 'turn-cache-concurrent-second', { sessionId: 'cache-session' })
  await waitFor(
    () => fixture.events.find((event) => event.id === 'turn-cache-concurrent-first'
      && event.type === 'done'),
    'first concurrent terminal',
    fixture,
  )
  await waitFor(
    () => fixture.events.find((event) => event.id === 'turn-cache-concurrent-second'
      && event.type === 'done'),
    'second concurrent terminal',
    fixture,
  )

  sendCacheTurn(fixture, 'turn-cache-after-concurrent', { sessionId: 'cache-session' })
  await waitFor(
    () => fixture.events.find((event) => event.id === 'turn-cache-after-concurrent'
      && (event.type === 'done' || event.type === 'error')),
    'post-concurrency authoritative terminal',
    fixture,
  )
  assert.deepEqual(
    structuredRecords(fixture)
      .filter((entry) => entry.kind === 'context-usage').map((entry) => entry.attempt),
    [1, 3, 4],
    'only the first concurrent claim may skip; both branches are barred from reseeding',
  )
})

test('a compaction that fails once is retried in the same session, which survives', async (t) => {
  const fixture = startFixture(t, 'recover')
  await waitFor(() => fixture.events.find((event) => event.type === 'ready'), 'ready', fixture)
  sendOverfullTurn(fixture)

  const terminal = await waitFor(
    () => fixture.events.find((event) => event.id === 'turn-context'
      && (event.type === 'done' || event.type === 'error')),
    'recovered turn terminal',
    fixture,
  )
  assert.deepEqual(terminal, { type: 'done', id: 'turn-context' })

  const records = fixture.records()
  const queries = records.filter((line) => line.startsWith('{'))
    .map(JSON.parse).filter((entry) => entry.kind === 'query')
  // Losing the session is what a person experiences as their conversation restarting, and it used
  // to be the FIRST response to a failed compaction rather than the last. The retry resumes the
  // same session; only if that fails too is the session rebuilt.
  assert.deepEqual(
    queries.map((entry) => entry.resume),
    ['overfull-session', 'overfull-session'],
    'a compaction that fails once must not cost the session',
  )
  assert.deepEqual(
    queries.map((entry) => entry.abortAlreadySignaled),
    [false, false],
    'the retry receives a new, live SDK abort controller',
  )
  assert.deepEqual(queries.map((entry) => entry.includeHookEvents), [true, true])
  assert.equal(records.includes('VERTEX_REQUEST_SUBMITTED_AFTER_FAILED_COMPACTION'), false)
  assert.equal(
    fixture.events.filter((event) => event.type === 'session_invalidated'
      && event.id === 'turn-context').length,
    0,
    'the session must survive a compaction failure the retry recovers from',
  )
  assert.equal(
    fixture.events.filter((event) => event.type === 'error'
      && event.id === 'turn-context').length,
    0,
  )
  assert.equal(
    fixture.events.filter((event) => event.id === 'turn-context'
      && event.compactResult === 'failed').length,
    0,
    'a recovered maintenance failure must not leave a durable failed-compaction row',
  )
  // The retry sends the original prompt into the existing session, so no history is rebuilt and
  // none is dropped. A user sees nothing at all, which is the point.
  const retryPrompt = records.filter((line) => line.startsWith('{'))
    .map(JSON.parse)
    .find((entry) => entry.kind === 'prompt' && entry.attempt === 2)?.text
  assert.ok(retryPrompt.endsWith('answer this exact current prompt'))
  assert.doesNotMatch(
    retryPrompt,
    /middle of this older turn omitted/,
    'a same-session retry must not smuggle in a bounded replay',
  )
  assert.deepEqual(
    fixture.events.filter((event) =>
      event.type === 'history_reduced' && event.id === 'turn-context'),
    [],
    'nothing was reduced, so nothing may claim it was',
  )

  // The number that decides when compaction runs must reach the app. Without it the meter measures
  // fill against the model's maximum while compaction answers to this, which is how a conversation
  // comes to compact at 40% of a shown window and look broken.
  const usageEvents = fixture.events.filter((event) => event.type === 'context_usage')
  assert.ok(usageEvents.length > 0, 'a resumed turn must report context usage')
  const reported = usageEvents.filter((event) => event.contextWindow !== null)
  assert.ok(reported.length > 0, 'a resumed turn must report context usage')
  assert.deepEqual(
    [...new Set(reported.map((event) => event.compactionThreshold))],
    [160000],
    'the provider-reported compaction threshold must be carried to the app',
  )
  assert.deepEqual(
    [...new Set(reported.map((event) => event.contextWindow))],
    [200000],
    'and it is a different number from the window',
  )
  // A cleared meter must clear the threshold too, or the next session is measured against the
  // limit of the one that was retired.
  for (const cleared of usageEvents.filter((event) => event.contextWindow === null)) {
    assert.equal(cleared.compactionThreshold, null)
  }
  assert.equal(
    fixture.events.some((event) =>
      event.type === 'compact_boundary' && event.id === 'turn-context'),
    false,
    'fresh-session history reduction must not masquerade as provider compaction',
  )
})

test('fresh recovery emits no history marker when the complete durable replay fits', async (t) => {
  const fixture = startFixture(t, 'recover')
  await waitFor(() => fixture.events.find((event) => event.type === 'ready'), 'ready', fixture)
  sendSmallRecoverableTurn(fixture)

  const terminal = await waitFor(
    () => fixture.events.find((event) => event.id === 'turn-small-recovery'
      && (event.type === 'done' || event.type === 'error')),
    'small recovered turn terminal',
    fixture,
  )
  assert.deepEqual(terminal, { type: 'done', id: 'turn-small-recovery' })
  assert.equal(
    fixture.events.some((event) =>
      event.type === 'history_reduced' && event.id === 'turn-small-recovery'),
    false,
    'changing provider sessions is not itself evidence that provider-visible history was reduced',
  )
})

test('a stale resumed Claude session retries with freshPrompt only on its replacement', async (t) => {
  const fixture = startFixture(t, 'stale-resume')
  await waitFor(() => fixture.events.find((event) => event.type === 'ready'), 'ready', fixture)
  sendDualPromptTurn(fixture, 'turn-stale-dual-prompt', {
    sessionId: 'expired-session',
    prompt: 'resumed prompt without repeated memory',
    freshPrompt: 'fresh prompt with the required memory attachment',
  })

  assert.deepEqual(await waitFor(
    () => fixture.events.find((event) => event.id === 'turn-stale-dual-prompt'
      && (event.type === 'done' || event.type === 'error')),
    'stale-session recovery terminal',
    fixture,
  ), { type: 'done', id: 'turn-stale-dual-prompt' })

  const records = structuredRecords(fixture)
  assert.deepEqual(
    records.filter((entry) => entry.kind === 'query').map((entry) => entry.resume),
    ['expired-session', null],
    'the existing provider session is tried before one replacement session is opened',
  )
  assert.deepEqual(
    records.filter((entry) => entry.kind === 'prompt').map(({ attempt, text }) => ({
      attempt, text,
    })),
    [
      { attempt: 1, text: 'resumed prompt without repeated memory' },
      { attempt: 2, text: 'fresh prompt with the required memory attachment' },
    ],
    'freshPrompt must not enter the resumed session, but must seed its fresh replacement',
  )
  assert.equal(
    fixture.events.filter((event) => event.type === 'session_invalidated'
      && event.id === 'turn-stale-dual-prompt'
      && event.reason === 'provider_session_expired').length,
    1,
  )
})

test('Claude guidance waits behind the resumed root prompt during context preflight', async (t) => {
  const fixture = startFixture(t, 'cache-steer-before-root', {
    contextControlTimeoutMs: 5_000,
  })
  await waitFor(() => fixture.events.find((event) => event.type === 'ready'), 'ready', fixture)
  sendDualPromptTurn(fixture, 'turn-steer-before-root', {
    sessionId: 'cache-session',
    prompt: 'resumed root prompt',
    freshPrompt: 'fresh root prompt',
  })
  await waitFor(
    () => structuredRecords(fixture).find((entry) => entry.kind === 'context-usage'),
    'held context preflight',
    fixture,
  )

  fixture.child.stdin.write(`${JSON.stringify({
    type: 'steer',
    turnId: 'turn-steer-before-root',
    steerId: 'steer-before-root',
    prompt: 'resumed-session guidance',
    freshPrompt: 'fresh-session guidance',
  })}\n`)
  fixture.child.stdin.write(`${JSON.stringify({
    type: 'ping',
    id: 'ping-after-preflight-steer',
  })}\n`)
  await waitFor(
    () => fixture.events.find((event) => event.type === 'pong'
      && event.id === 'ping-after-preflight-steer'),
    'daemon receipt after held guidance',
    fixture,
  )
  assert.equal(
    fixture.events.some((event) => event.type === 'steer_ack'
      && event.steerId === 'steer-before-root'),
    false,
    'guidance is not acknowledged while the root prompt is still held in preflight',
  )
  assert.equal(
    structuredRecords(fixture).some((entry) => entry.kind === 'prompt'),
    false,
    'guidance cannot become the provider stream\'s first user message',
  )

  fs.writeFileSync(`${fixture.capture}.release-preflight`, '')
  assert.deepEqual(await waitFor(
    () => fixture.events.find((event) => event.id === 'turn-steer-before-root'
      && (event.type === 'done' || event.type === 'error')),
    'steered resumed turn terminal',
    fixture,
  ), { type: 'done', id: 'turn-steer-before-root' })
  await waitFor(
    () => fixture.events.find((event) => event.type === 'steer_ack'
      && event.steerId === 'steer-before-root'),
    'post-root guidance acknowledgement',
    fixture,
  )

  const delivered = structuredRecords(fixture)
    .filter((entry) => entry.kind === 'prompt' || entry.kind === 'guidance')
    .map(({ kind, text }) => ({ kind, text }))
  assert.deepEqual(delivered, [
    { kind: 'prompt', text: 'resumed root prompt' },
    { kind: 'guidance', text: 'resumed-session guidance' },
  ])
})

test('a resumed synthetic no-output success gets one bounded fresh replay', async (t) => {
  const fixture = startFixture(t, 'no-output-recover', { authMode: 'vertex' })
  await waitFor(() => fixture.events.find((event) => event.type === 'ready'), 'ready', fixture)
  sendSmallRecoverableTurn(fixture, 'turn-no-output-recover')

  const terminal = await waitFor(
    () => fixture.events.find((event) => event.id === 'turn-no-output-recover'
      && (event.type === 'done' || event.type === 'error')),
    'no-output recovered terminal',
    fixture,
  )
  assert.deepEqual(terminal, { type: 'done', id: 'turn-no-output-recover' })
  const records = structuredRecords(fixture)
  assert.deepEqual(
    records.filter((entry) => entry.kind === 'query').map((entry) => entry.resume),
    ['overfull-session', null],
    'the unhealthy opaque session is replaced exactly once',
  )
  assert.equal(
    fixture.events.filter((event) => event.id === 'turn-no-output-recover'
      && event.type === 'session_invalidated'
      && event.reason === 'provider_no_output').length,
    1,
  )
  assert.equal(
    fixture.events.filter((event) => event.id === 'turn-no-output-recover'
      && event.type === 'delta').length,
    1,
    'the synthetic sentinel never becomes visible output',
  )
  assert.match(fixture.stderr, /\[recovery\]\[no-output\].*action=fresh_replay/)
  assert.match(fixture.stderr, /\[recovery\]\[no-output\].*outcome=recovered attempts=2/)
})

test('a stream-idle throw before output gets the same one-shot fresh recovery', async (t) => {
  const fixture = startFixture(t, 'no-output-idle-throw', { authMode: 'vertex' })
  await waitFor(() => fixture.events.find((event) => event.type === 'ready'), 'ready', fixture)
  sendSmallRecoverableTurn(fixture, 'turn-no-output-idle')

  assert.deepEqual(await waitFor(
    () => fixture.events.find((event) => event.id === 'turn-no-output-idle'
      && (event.type === 'done' || event.type === 'error')),
    'stream-idle recovered terminal',
    fixture,
  ), { type: 'done', id: 'turn-no-output-idle' })
  assert.deepEqual(
    structuredRecords(fixture)
      .filter((entry) => entry.kind === 'query').map((entry) => entry.resume),
    ['overfull-session', null],
  )
  assert.match(fixture.stderr, /classification=stream_idle_timeout/)
})

for (const [scenario, description] of [
  ['no-output-init-eof', 'setup-only clean EOF'],
  ['no-output-assistant-eof', 'synthetic-assistant-only clean EOF'],
]) {
  test(`${description} gets one bounded fresh recovery`, async (t) => {
    const fixture = startFixture(t, scenario, { authMode: 'vertex' })
    await waitFor(() => fixture.events.find((event) => event.type === 'ready'), 'ready', fixture)
    const turnID = `turn-${scenario}`
    sendSmallRecoverableTurn(fixture, turnID)

    assert.deepEqual(await waitFor(
      () => fixture.events.find((event) => event.id === turnID
        && (event.type === 'done' || event.type === 'error')),
      `${description} recovered terminal`,
      fixture,
    ), { type: 'done', id: turnID })
    assert.deepEqual(
      structuredRecords(fixture)
        .filter((entry) => entry.kind === 'query').map((entry) => entry.resume),
      ['overfull-session', null],
      'clean zero-output EOF retires the resumed session and spends exactly one fresh replay',
    )
    assert.equal(fixture.events.filter((event) => event.id === turnID
      && event.type === 'session_invalidated'
      && event.reason === 'provider_no_output').length, 1)
    assert.match(fixture.stderr, /classification=zero_output_eof/)
  })
}

test('an answer after an earlier terminal result is still counted as output', async (t) => {
  // Field incident 2026-08-14: a resumed turn opened with a background `task_notification`, the SDK
  // closed that cycle with a zero-API result, and the model then ran four Bash tools and streamed
  // two answers over the next four minutes. The user was shown "Couldn't reach Claude —
  // no_output_replay_refused" anyway, because the liveness ledger was read off a one-shot watchdog
  // that had already stopped. Liveness must be answered for the whole turn, not until the first
  // terminal record.
  const fixture = startFixture(t, 'result-then-real-answer', { authMode: 'vertex' })
  await waitFor(() => fixture.events.find((event) => event.type === 'ready'), 'ready', fixture)
  sendSmallRecoverableTurn(fixture, 'turn-result-then-real-answer')

  const terminal = await waitFor(
    () => fixture.events.find((event) => event.id === 'turn-result-then-real-answer'
      && (event.type === 'done' || event.type === 'error')),
    'answer-after-result terminal',
    fixture,
  )
  assert.deepEqual(terminal, { type: 'done', id: 'turn-result-then-real-answer' },
    'a turn that produced an answer must not be reported as no-output')
  assert.equal(
    structuredRecords(fixture).filter((entry) => entry.kind === 'query').length,
    1,
    'a turn that answered is never replayed',
  )
  assert.equal(fixture.events.filter((event) => event.id === 'turn-result-then-real-answer'
    && event.type === 'session_invalidated').length, 0,
    'a healthy answered turn keeps its session')
  assert.doesNotMatch(fixture.stderr, /\[recovery\]\[no-output\] turn=turn-result-then-real-answer/)
})

test('Claude input stays open until background work and its root response complete', async (t) => {
  const fixture = startFixture(t, 'background-input-lifetime', { authMode: 'vertex' })
  await waitFor(() => fixture.events.find((event) => event.type === 'ready'), 'ready', fixture)
  sendSmallRecoverableTurn(fixture, 'turn-background-input-lifetime')

  const terminal = await waitFor(
    () => fixture.events.find((event) => event.id === 'turn-background-input-lifetime'
      && (event.type === 'done' || event.type === 'error')),
    'background input lifetime terminal',
    fixture,
  )
  assert.deepEqual(terminal, { type: 'done', id: 'turn-background-input-lifetime' })
  assert.deepEqual(
    structuredRecords(fixture).filter((entry) => entry.kind === 'input-lifetime'),
    [
      { kind: 'input-lifetime', phase: 'root-result', inputClosed: false },
      { kind: 'input-lifetime', phase: 'notification-result', inputClosed: false },
      { kind: 'input-lifetime', phase: 'final-result', inputClosed: true },
    ],
  )
})

test('a fresh setup-only EOF fails closed without an automatic duplicate request', async (t) => {
  const fixture = startFixture(t, 'no-output-fresh-init-eof', { authMode: 'vertex' })
  await waitFor(() => fixture.events.find((event) => event.type === 'ready'), 'ready', fixture)
  sendSmallRecoverableTurn(fixture, 'turn-fresh-init-eof', { sessionId: null })

  const terminal = await waitFor(
    () => fixture.events.find((event) => event.id === 'turn-fresh-init-eof'
      && (event.type === 'done' || event.type === 'error')),
    'fresh setup-only EOF terminal',
    fixture,
  )
  assert.equal(terminal.type, 'error')
  assert.equal(terminal.providerError?.providerType, 'provider_no_output')
  assert.equal(terminal.providerError?.code, 'no_output_replay_refused')
  assert.equal(terminal.providerError?.replayRefusal, 'fresh_session')
  assert.equal(terminal.providerError?.resumed, false)
  assert.equal(terminal.providerError?.noProviderWork, true)
  assert.equal(structuredRecords(fixture).filter((entry) => entry.kind === 'query').length, 1,
    'a byte-identical fresh request is never sent twice automatically')
  assert.equal(fixture.events.filter((event) => event.id === 'turn-fresh-init-eof'
    && event.type === 'session_invalidated'
    && event.reason === 'provider_no_output').length, 1)
})

test('no-output recovery spends only one fresh replay and then emits structured failure', async (t) => {
  const fixture = startFixture(t, 'no-output-exhausted', { authMode: 'vertex' })
  await waitFor(() => fixture.events.find((event) => event.type === 'ready'), 'ready', fixture)
  sendSmallRecoverableTurn(fixture, 'turn-no-output-exhausted')

  const terminal = await waitFor(
    () => fixture.events.find((event) => event.id === 'turn-no-output-exhausted'
      && (event.type === 'done' || event.type === 'error')),
    'no-output exhausted terminal',
    fixture,
  )
  assert.equal(terminal.type, 'error')
  assert.equal(terminal.errorKind, 'network')
  assert.deepEqual(terminal.providerError, {
    providerType: 'provider_no_output',
    code: 'no_output_after_fresh_replay',
    diagnosticCode: 'claude_no_output_after_fresh_replay',
    resumed: true,
    noProviderWork: true,
    freshReplayAttempted: true,
  })
  assert.equal(
    structuredRecords(fixture).filter((entry) => entry.kind === 'query').length,
    2,
    'one resumed attempt plus one fresh attempt, never a loop',
  )
  const invalidations = fixture.events.filter((event) =>
    event.id === 'turn-no-output-exhausted'
      && event.type === 'session_invalidated'
      && event.reason === 'provider_no_output')
  assert.equal(invalidations.length, 2,
    'both the original session and failed replacement session are retired')

  sendSmallRecoverableTurn(fixture, 'turn-no-output-after-exhaustion', { sessionId: null })
  await waitFor(
    () => fixture.events.find((event) => event.id === 'turn-no-output-after-exhaustion'
      && (event.type === 'done' || event.type === 'error')),
    'turn after exhausted recovery',
    fixture,
  )
  const laterQuery = structuredRecords(fixture)
    .filter((entry) => entry.kind === 'query').at(-1)
  assert.equal(laterQuery.resume, null,
    'the failed replacement session is unavailable to the next send')
})

for (const scenario of [
  'no-output-malformed-result',
  'no-output-thinking-tokens',
  'no-output-prompt-suggestion',
  'no-output-nonempty-thinking-start',
]) {
  test(`${scenario} refuses automatic replay`, async (t) => {
    const fixture = startFixture(t, scenario, { authMode: 'vertex' })
    await waitFor(() => fixture.events.find((event) => event.type === 'ready'), 'ready', fixture)
    sendSmallRecoverableTurn(fixture, `turn-${scenario}`)

    const terminal = await waitFor(
      () => fixture.events.find((event) => event.id === `turn-${scenario}`
        && (event.type === 'done' || event.type === 'error')),
      `${scenario} terminal`,
      fixture,
    )
    assert.equal(terminal.type, 'error')
    assert.equal(terminal.providerError?.code, 'no_output_replay_refused')
    assert.equal(
      structuredRecords(fixture).filter((entry) => entry.kind === 'query').length,
      1,
      'unknown/work-bearing traffic cannot authorize replay',
    )
  })
}

test('a rejected subscription usage event retains usage-limit precedence', async (t) => {
  const fixture = startFixture(t, 'no-output-rejected-limit', { authMode: 'subscription' })
  await waitFor(() => fixture.events.find((event) => event.type === 'ready'), 'ready', fixture)
  sendSmallRecoverableTurn(fixture, 'turn-no-output-rejected-limit')

  const terminal = await waitFor(
    () => fixture.events.find((event) => event.id === 'turn-no-output-rejected-limit'
      && (event.type === 'done' || event.type === 'error')),
    'usage-limit terminal',
    fixture,
  )
  assert.equal(terminal.type, 'error')
  assert.equal(terminal.errorKind, 'usage_limit')
  assert.equal(structuredRecords(fixture).filter((entry) => entry.kind === 'query').length, 1)
})

for (const [scenario, kind, status] of [
  ['no-output-429', 'rate_limit', 429],
  ['no-output-503', 'server', 503],
]) {
  test(`${status} retry evidence wins over generic synthetic no-output recovery`, async (t) => {
    const fixture = startFixture(t, scenario, { authMode: 'vertex' })
    await waitFor(() => fixture.events.find((event) => event.type === 'ready'), 'ready', fixture)
    sendSmallRecoverableTurn(fixture, `turn-${scenario}`)

    const terminal = await waitFor(
      () => fixture.events.find((event) => event.id === `turn-${scenario}`
        && (event.type === 'done' || event.type === 'error')),
      `${status} terminal`,
      fixture,
    )
    assert.equal(terminal.type, 'error')
    assert.equal(terminal.errorKind, kind)
    assert.equal(terminal.providerError?.status, status)
    assert.equal(structuredRecords(fixture).filter((entry) => entry.kind === 'query').length, 1)
    assert.doesNotMatch(JSON.stringify(terminal), /private|payload|retry fixture/i)
  })
}

test('latest api-retry evidence replaces an older retry classification', async (t) => {
  const latestNetwork = startFixture(t, 'no-output-retry-429-network', { authMode: 'vertex' })
  await waitFor(() => latestNetwork.events.find((event) => event.type === 'ready'),
    'latest-network ready', latestNetwork)
  sendSmallRecoverableTurn(latestNetwork, 'turn-latest-network')
  const networkTerminal = await waitFor(
    () => latestNetwork.events.find((event) => event.id === 'turn-latest-network'
      && (event.type === 'done' || event.type === 'error')),
    'latest-network terminal', latestNetwork,
  )
  assert.equal(networkTerminal.providerError?.code, 'no_output_after_fresh_replay')
  assert.equal(structuredRecords(latestNetwork).filter((entry) => entry.kind === 'query').length, 2)
  assert.match(latestNetwork.stderr, /apiRetryStatus=none/)

  const latest429 = startFixture(t, 'no-output-retry-network-429', { authMode: 'vertex' })
  await waitFor(() => latest429.events.find((event) => event.type === 'ready'),
    'latest-429 ready', latest429)
  sendSmallRecoverableTurn(latest429, 'turn-latest-429')
  const rateLimitTerminal = await waitFor(
    () => latest429.events.find((event) => event.id === 'turn-latest-429'
      && (event.type === 'done' || event.type === 'error')),
    'latest-429 terminal', latest429,
  )
  assert.equal(rateLimitTerminal.errorKind, 'rate_limit')
  assert.equal(rateLimitTerminal.providerError?.status, 429)
  assert.equal(structuredRecords(latest429).filter((entry) => entry.kind === 'query').length, 1)
})

test('a later real error result supersedes an earlier synthetic response cycle', async (t) => {
  const fixture = startFixture(t, 'no-output-synthetic-then-error', { authMode: 'vertex' })
  await waitFor(() => fixture.events.find((event) => event.type === 'ready'), 'ready', fixture)
  sendSmallRecoverableTurn(fixture, 'turn-synthetic-then-error')

  const terminal = await waitFor(
    () => fixture.events.find((event) => event.id === 'turn-synthetic-then-error'
      && (event.type === 'done' || event.type === 'error')),
    'later provider error terminal', fixture,
  )
  assert.equal(terminal.type, 'error')
  assert.notEqual(terminal.errorKind, 'rate_limit',
    'the later terminal result supersedes an earlier 429 retry notice')
  assert.notEqual(terminal.providerError?.providerType, 'provider_no_output')
  assert.equal(structuredRecords(fixture).filter((entry) => entry.kind === 'query').length, 1)
})

test('thinking cannot keep a no-answer Vertex turn alive beyond the wall budget', async (t) => {
  const fixture = startFixture(t, 'no-output-thinking-stall', {
    authMode: 'vertex',
    firstResponseTimeoutMs: 2_000,
    firstRealOutputTimeoutMs: 80,
  })
  await waitFor(() => fixture.events.find((event) => event.type === 'ready'), 'ready', fixture)
  sendSmallRecoverableTurn(fixture, 'turn-thinking-stall')

  const terminal = await waitFor(
    () => fixture.events.find((event) => event.id === 'turn-thinking-stall'
      && (event.type === 'done' || event.type === 'error')),
    'thinking wall-timeout terminal', fixture,
  )
  assert.equal(terminal.type, 'error')
  assert.equal(terminal.providerError?.providerType, 'provider_first_output_timeout')
  assert.equal(structuredRecords(fixture).filter((entry) => entry.kind === 'query').length, 1,
    'thinking is unsafe provider work and may not be replayed')
  assert.match(fixture.stderr, /limit=wall/)
})

test('thinking before a stream-idle failure retires the session without automatic replay', async (t) => {
  const fixture = startFixture(t, 'no-output-thinking-idle-throw', { authMode: 'vertex' })
  await waitFor(() => fixture.events.find((event) => event.type === 'ready'), 'ready', fixture)
  sendSmallRecoverableTurn(fixture, 'turn-thinking-idle-throw')

  const terminal = await waitFor(
    () => fixture.events.find((event) => event.id === 'turn-thinking-idle-throw'
      && (event.type === 'done' || event.type === 'error')),
    'thinking stream-idle terminal',
    fixture,
  )
  assert.equal(terminal.type, 'error')
  assert.equal(terminal.providerError?.providerType, 'provider_no_output')
  assert.equal(terminal.providerError?.code, 'no_output_replay_refused')
  assert.equal(terminal.providerError?.replayRefusal, 'provider_work_observed')
  assert.equal(terminal.providerError?.noProviderWork, false)
  assert.equal(structuredRecords(fixture).filter((entry) => entry.kind === 'query').length, 1,
    'real provider thinking is not safe evidence for an automatic duplicate request')
  assert.equal(fixture.events.filter((event) => event.id === 'turn-thinking-idle-throw'
    && event.type === 'session_invalidated'
    && event.reason === 'provider_no_output').length, 1,
  'the next explicit retry must start on a fresh provider session')
})

test('Stop after the synthetic terminal prevents a fresh replay', async (t) => {
  const fixture = startFixture(t, 'no-output-interrupt-before-replay', { authMode: 'vertex' })
  await waitFor(() => fixture.events.find((event) => event.type === 'ready'), 'ready', fixture)
  sendSmallRecoverableTurn(fixture, 'turn-stop-before-replay')
  await waitFor(() => fixture.records().includes('original-synthetic-terminal-held'),
    'held original synthetic terminal', fixture)
  fixture.child.stdin.write(`${JSON.stringify({
    type: 'interrupt', id: 'stop-before-replay', turnId: 'turn-stop-before-replay',
  })}\n`)

  assert.deepEqual(await waitFor(
    () => fixture.events.find((event) => event.id === 'turn-stop-before-replay'
      && (event.type === 'done' || event.type === 'error')),
    'stopped original terminal', fixture,
  ), { type: 'done', id: 'turn-stop-before-replay', interrupted: true })
  assert.equal(structuredRecords(fixture).filter((entry) => entry.kind === 'query').length, 1)
})

test('Stop during fresh replay retires its newly assigned provider session', async (t) => {
  const fixture = startFixture(t, 'no-output-interrupt-during-replay', { authMode: 'vertex' })
  await waitFor(() => fixture.events.find((event) => event.type === 'ready'), 'ready', fixture)
  sendSmallRecoverableTurn(fixture, 'turn-stop-during-replay')
  await waitFor(() => fixture.records().includes('fresh-replay-session-open'),
    'fresh replay session', fixture)
  fixture.child.stdin.write(`${JSON.stringify({
    type: 'interrupt', id: 'stop-during-replay', turnId: 'turn-stop-during-replay',
  })}\n`)

  assert.deepEqual(await waitFor(
    () => fixture.events.find((event) => event.id === 'turn-stop-during-replay'
      && (event.type === 'done' || event.type === 'error')),
    'stopped fresh replay', fixture,
  ), { type: 'done', id: 'turn-stop-during-replay', interrupted: true })
  assert.equal(structuredRecords(fixture).filter((entry) => entry.kind === 'query').length, 2)
  assert.equal(fixture.events.filter((event) => event.id === 'turn-stop-during-replay'
    && event.type === 'session_invalidated'
    && event.reason === 'provider_no_output').length, 2,
  'both the original and interrupted replacement session are retired')
})

test('provider-side effects refuse automatic no-output replay', async (t) => {
  const fixture = startFixture(t, 'no-output-side-effect', { authMode: 'vertex' })
  await waitFor(() => fixture.events.find((event) => event.type === 'ready'), 'ready', fixture)
  sendSmallRecoverableTurn(fixture, 'turn-no-output-side-effect')

  const terminal = await waitFor(
    () => fixture.events.find((event) => event.id === 'turn-no-output-side-effect'
      && (event.type === 'done' || event.type === 'error')),
    'side-effect refusal terminal',
    fixture,
  )
  assert.equal(terminal.type, 'error')
  assert.equal(terminal.providerError?.code, 'no_output_replay_refused')
  assert.equal(terminal.providerError?.replayRefusal, 'provider_work_observed')
  assert.equal(terminal.providerError?.freshReplayAttempted, false)
  assert.equal(
    structuredRecords(fixture).filter((entry) => entry.kind === 'query').length,
    1,
  )
  assert.equal(
    fixture.records().filter((entry) => entry === 'no-output-hook-effect-once').length,
    1,
    'the side effect must never be duplicated',
  )
})

test('internal PostCompact lifecycle remains safe for bounded no-output replay', async (t) => {
  const fixture = startFixture(t, 'no-output-post-compact', { authMode: 'vertex' })
  await waitFor(() => fixture.events.find((event) => event.type === 'ready'), 'ready', fixture)
  sendSmallRecoverableTurn(fixture, 'turn-no-output-post-compact')

  assert.deepEqual(await waitFor(
    () => fixture.events.find((event) => event.id === 'turn-no-output-post-compact'
      && (event.type === 'done' || event.type === 'error')),
    'PostCompact no-output recovery terminal',
    fixture,
  ), { type: 'done', id: 'turn-no-output-post-compact' })
  assert.deepEqual(
    structuredRecords(fixture)
      .filter((entry) => entry.kind === 'query').map((entry) => entry.resume),
    ['overfull-session', null],
    'read-only PostCompact bookkeeping must not block the one bounded fresh replay',
  )
  assert.equal(
    fixture.records().filter((entry) => entry === 'post-compact-lifecycle-once').length,
    1,
    'the replacement response succeeds without repeating the fixture lifecycle',
  )
  assert.equal(
    fixture.events.filter((event) => event.type === 'compact_boundary'
      && event.id === 'turn-no-output-post-compact').length,
    1,
    'the provider compaction boundary remains observable even though recovery follows it',
  )
  assert.match(fixture.stderr, /\[recovery\]\[no-output\].*action=fresh_replay/)
})

test('acknowledged guidance refuses automatic no-output replay', async (t) => {
  const fixture = startFixture(t, 'no-output-guidance', { authMode: 'vertex' })
  await waitFor(() => fixture.events.find((event) => event.type === 'ready'), 'ready', fixture)
  sendSmallRecoverableTurn(fixture, 'turn-no-output-guidance')
  await waitFor(
    () => structuredRecords(fixture).find((entry) => entry.kind === 'prompt'),
    'root prompt delivery',
    fixture,
  )
  fixture.child.stdin.write(`${JSON.stringify({
    type: 'steer',
    turnId: 'turn-no-output-guidance',
    steerId: 'steer-no-output-guidance',
    prompt: 'additional accepted guidance',
  })}\n`)
  await waitFor(
    () => fixture.events.find((event) => event.type === 'steer_ack'
      && event.steerId === 'steer-no-output-guidance'),
    'guidance acknowledgement',
    fixture,
  )

  const terminal = await waitFor(
    () => fixture.events.find((event) => event.id === 'turn-no-output-guidance'
      && (event.type === 'done' || event.type === 'error')),
    'guidance refusal terminal',
    fixture,
  )
  assert.equal(terminal.type, 'error')
  assert.equal(terminal.providerError?.code, 'no_output_replay_refused')
  assert.equal(terminal.providerError?.replayRefusal, 'guidance_acknowledged')
  assert.equal(
    structuredRecords(fixture).filter((entry) => entry.kind === 'query').length,
    1,
  )
  assert.equal(
    structuredRecords(fixture).filter((entry) => entry.kind === 'guidance').length,
    1,
    'acknowledged guidance belongs to the original stream and is never auto-duplicated',
  )
})

test('a repeatedly failing compaction is terminal after a bounded number of attempts', async (t) => {
  const fixture = startFixture(t, 'repeat')
  await waitFor(() => fixture.events.find((event) => event.type === 'ready'), 'ready', fixture)
  sendOverfullTurn(fixture, 'turn-repeat')

  const terminal = await waitFor(
    () => fixture.events.find((event) => event.id === 'turn-repeat'
      && (event.type === 'done' || event.type === 'error')),
    'bounded repeated failure',
    fixture,
  )
  assert.equal(terminal.type, 'error')
  assert.equal(terminal.errorKind, 'context_limit')
  const records = fixture.records()
  assert.equal(
    records.filter((line) => line.startsWith('{'))
      .map(JSON.parse).filter((entry) => entry.kind === 'query').length,
    3,
    'same session, then one rebuilt session, then stop — bounded, never a loop',
  )
  assert.equal(records.includes('VERTEX_REQUEST_SUBMITTED_AFTER_FAILED_COMPACTION'), false)
  assert.equal(
    fixture.events.filter((event) => event.id === 'turn-repeat'
      && event.compactResult === 'failed').length,
    1,
    'the terminal second failure remains visible',
  )
})

// Issue 47. Both lanes, because the bug was reported as Vertex-only and is not: nothing on the
// failure path reads AUTH_MODE, and the original was reproduced live on the subscription lane.
for (const authMode of ['apikey', 'vertex']) {
  test(`a first message that fails compaction stops at one attempt (${authMode})`, async (t) => {
    const fixture = startFixture(t, 'first-message-skill', { authMode })
    await waitFor(() => fixture.events.find((event) => event.type === 'ready'), 'ready', fixture)
    sendFirstMessageTurn(fixture, 'turn-first-message')

    const terminal = await waitFor(
      () => fixture.events.find((event) => event.id === 'turn-first-message'
        && (event.type === 'done' || event.type === 'error')),
      'first-message terminal',
      fixture,
    )
    assert.equal(terminal.type, 'error')
    assert.equal(terminal.errorKind, 'context_limit')

    const queries = fixture.records().filter((line) => line.startsWith('{'))
      .map(JSON.parse).filter((entry) => entry.kind === 'query')
    // The whole point of the fix: not 2, not 3. On a first message `priorHistory` is empty and the
    // only session to resume is the one this turn just created, so a retry would re-send identical
    // bytes. Spending them only made the same card arrive a minute later.
    assert.equal(queries.length, 1, 'a first message must not spend a retry that cannot differ')
    assert.equal(queries.every((entry) => !entry.resume), true, 'no query may resume a dead session')
    assert.equal(
      fixture.records().includes('VERTEX_REQUEST_SUBMITTED_AFTER_FAILED_COMPACTION'), false)
  })
}

test('a first message never pays for a bounded rebuild that would re-send identical bytes', async (t) => {
  // `repeat` fails compaction on every attempt, and this scenario streams no assistant or tool
  // frame, so `safeToReplay` is genuinely true and recovery really is attempted. The same-session
  // retry is still spent (it resumes a session that now holds the failed attempt, so it can
  // differ); the fresh rebuild is not, because an empty priorHistory makes it byte-identical.
  // Two queries, not three. The resumed-session equivalent above still asserts three.
  const fixture = startFixture(t, 'repeat')
  await waitFor(() => fixture.events.find((event) => event.type === 'ready'), 'ready', fixture)
  sendFirstMessageTurn(fixture, 'turn-first-repeat')

  const terminal = await waitFor(
    () => fixture.events.find((event) => event.id === 'turn-first-repeat'
      && (event.type === 'done' || event.type === 'error')),
    'first-message repeat terminal',
    fixture,
  )
  assert.equal(terminal.type, 'error')
  assert.equal(terminal.errorKind, 'context_limit')
  const queries = fixture.records().filter((line) => line.startsWith('{'))
    .map(JSON.parse).filter((entry) => entry.kind === 'query')
  assert.equal(queries.length, 2,
    'the same-session retry is worth spending; the identical fresh rebuild is not')
  assert.equal(
    fixture.records().includes('VERTEX_REQUEST_SUBMITTED_AFTER_FAILED_COMPACTION'), false)
})

// The demotion follows the lane's real window, not the model name. Opus 4.8 reaches 1M only through
// the `[1m]` variant, which is deliberately not applied on Vertex, so the SAME default model is a
// 1M lane on apikey and a 200K lane on Vertex. That is why a Vertex Opus user hit issue 47 while a
// subscription Opus user did not.
for (const lane of [
  { authMode: 'vertex', demoted: true, why: 'Vertex never gets the [1m] variant, so Opus is 200K' },
  { authMode: 'apikey', demoted: false, why: 'apikey resolves Opus 4.8 to [1m], which seats it' },
]) {
  test(`the oversized-skill demotion follows the lane window (${lane.authMode})`, async (t) => {
    const fixture = startFixture(t, 'recover', { authMode: lane.authMode })
    await waitFor(() => fixture.events.find((event) => event.type === 'ready'), 'ready', fixture)
    sendOverfullTurn(fixture, 'turn-demotion')
    await waitFor(
      () => fixture.events.find((event) => event.id === 'turn-demotion'
        && (event.type === 'done' || event.type === 'error')),
      'demotion terminal',
      fixture,
    )
    const queries = fixture.records().filter((line) => line.startsWith('{'))
      .map(JSON.parse).filter((entry) => entry.kind === 'query')
    assert.ok(queries.length >= 1)
    for (const entry of queries) {
      assert.equal(
        entry.skillOverrides?.['claude-api'],
        lane.demoted ? 'user-invocable-only' : undefined,
        lane.why,
      )
    }
  })
}

test('compaction failure after provider/tool activity never replays possible side effects', async (t) => {
  const fixture = startFixture(t, 'side-effect')
  await waitFor(() => fixture.events.find((event) => event.type === 'ready'), 'ready', fixture)
  sendOverfullTurn(fixture, 'turn-side-effect')

  const terminal = await waitFor(
    () => fixture.events.find((event) => event.id === 'turn-side-effect'
      && (event.type === 'done' || event.type === 'error')),
    'side-effect-safe terminal',
    fixture,
  )
  assert.equal(terminal.type, 'error')
  assert.equal(terminal.errorKind, 'context_limit')
  const records = fixture.records()
  assert.equal(records.filter((line) => line === 'tool-effect-once').length, 1)
  assert.equal(
    records.filter((line) => line.startsWith('{'))
      .map(JSON.parse).filter((entry) => entry.kind === 'query').length,
    1,
  )
  assert.equal(records.includes('VERTEX_REQUEST_SUBMITTED_AFTER_FAILED_COMPACTION'), false)
  assert.equal(
    fixture.events.filter((event) => event.id === 'turn-side-effect'
      && event.compactResult === 'failed').length,
    1,
    'an unsafe-to-replay failure remains visible',
  )
})

test('unknown/system task lifecycle evidence also blocks an automatic prompt replay', async (t) => {
  const fixture = startFixture(t, 'system-side-effect')
  await waitFor(() => fixture.events.find((event) => event.type === 'ready'), 'ready', fixture)
  sendOverfullTurn(fixture, 'turn-system-side-effect')

  const terminal = await waitFor(
    () => fixture.events.find((event) => event.id === 'turn-system-side-effect'
      && (event.type === 'done' || event.type === 'error')),
    'system-side-effect-safe terminal',
    fixture,
  )
  assert.equal(terminal.type, 'error')
  assert.equal(terminal.errorKind, 'context_limit')
  const records = fixture.records()
  assert.equal(records.filter((line) => line === 'tool-effect-once').length, 1)
  assert.equal(
    records.filter((line) => line.startsWith('{'))
      .map(JSON.parse).filter((entry) => entry.kind === 'query').length,
    1,
  )
  assert.equal(records.includes('VERTEX_REQUEST_SUBMITTED_AFTER_FAILED_COMPACTION'), false)
})

test('an executable prompt hook blocks replay before compaction failure', async (t) => {
  const fixture = startFixture(t, 'hook-side-effect')
  await waitFor(() => fixture.events.find((event) => event.type === 'ready'), 'ready', fixture)
  sendOverfullTurn(fixture, 'turn-hook-side-effect')

  const terminal = await waitFor(
    () => fixture.events.find((event) => event.id === 'turn-hook-side-effect'
      && (event.type === 'done' || event.type === 'error')),
    'hook-side-effect-safe terminal',
    fixture,
  )
  assert.equal(terminal.type, 'error')
  assert.equal(terminal.errorKind, 'context_limit')
  const records = fixture.records()
  assert.equal(records.filter((line) => line === 'prompt-hook-effect-once').length, 1)
  assert.equal(
    records.filter((line) => line.startsWith('{'))
      .map(JSON.parse).filter((entry) => entry.kind === 'query').length,
    1,
  )
  assert.equal(records.includes('VERTEX_REQUEST_SUBMITTED_AFTER_FAILED_COMPACTION'), false)
})

test('a huge current prompt is rejected before fresh SDK input delivery', async (t) => {
  const fixture = startFixture(t, 'fresh-too-large')
  await waitFor(() => fixture.events.find((event) => event.type === 'ready'), 'ready', fixture)
  sendHugeFreshTurn(fixture)

  const terminal = await waitFor(
    () => fixture.events.find((event) => event.id === 'turn-huge-fresh'
      && (event.type === 'done' || event.type === 'error')),
    'fresh prompt preflight terminal',
    fixture,
  )
  assert.equal(terminal.type, 'error')
  assert.equal(terminal.errorKind, 'context_limit')
  assert.equal(terminal.providerError?.providerType, 'input_too_large')
  assert.equal(terminal.providerError?.code, 'prompt_preflight_limit')
  assert.equal(terminal.providerError?.terminalReason, 'prompt_too_long')
  assert.equal(terminal.reconnectRequired, undefined)

  const records = fixture.records()
  assert.equal(
    records.filter((line) => line.startsWith('{'))
      .map(JSON.parse).filter((entry) => entry.kind === 'query').length,
    1,
  )
  assert.equal(
    records.filter((line) => line.startsWith('{'))
      .map(JSON.parse).filter((entry) => entry.kind === 'prompt').length,
    0,
    'preflight rejection must close input without pushing any user message',
  )
})

test('a wedged applyFlagSettings control recovers instead of hanging or sending over limit', async (t) => {
  const fixture = startFixture(t, 'apply-hangs')
  await waitFor(() => fixture.events.find((event) => event.type === 'ready'), 'ready', fixture)
  sendOverfullTurn(fixture, 'turn-apply-hangs')

  const terminal = await waitFor(
    () => fixture.events.find((event) => event.id === 'turn-apply-hangs'
      && (event.type === 'done' || event.type === 'error')),
    'applyFlagSettings recovery',
    fixture,
  )
  assert.deepEqual(terminal, { type: 'done', id: 'turn-apply-hangs' })
  const records = fixture.records()
  assert.ok(records.some((line) => line.includes('"kind":"apply-settings"')))
  assert.equal(
    records.filter((line) => line.startsWith('{'))
      .map(JSON.parse).filter((entry) => entry.kind === 'query').length,
    3,
    'same session, then one rebuilt session, then stop — bounded, never a loop',
  )
  assert.equal(records.includes('VERTEX_REQUEST_SUBMITTED_AFTER_FAILED_COMPACTION'), false)
  assert.deepEqual(
    fixture.events.filter((event) =>
      event.type === 'history_reduced' && event.id === 'turn-apply-hangs'),
    [{
      type: 'history_reduced',
      id: 'turn-apply-hangs',
      omittedMessages: 0,
      shortenedMessages: 2,
      reason: 'preflight_context_limit',
    }],
    'proactive recovery retains its preflight reason instead of masquerading as failed compaction',
  )
})

test('a wedged context-usage control falls back to bounded fresh replay', async (t) => {
  const fixture = startFixture(t, 'usage-hangs')
  await waitFor(() => fixture.events.find((event) => event.type === 'ready'), 'ready', fixture)
  sendOverfullTurn(fixture, 'turn-usage-hangs')

  const terminal = await waitFor(
    () => fixture.events.find((event) => event.id === 'turn-usage-hangs'
      && (event.type === 'done' || event.type === 'error')),
    'context-usage timeout recovery',
    fixture,
  )
  assert.deepEqual(terminal, { type: 'done', id: 'turn-usage-hangs' })
  const records = fixture.records()
  assert.equal(
    records.filter((line) => line.startsWith('{'))
      .map(JSON.parse).filter((entry) => entry.kind === 'query').length,
    3,
    'same session, then one rebuilt session, then stop — bounded, never a loop',
  )
  assert.equal(records.includes('VERTEX_REQUEST_SUBMITTED_AFTER_FAILED_COMPACTION'), false)
  assert.deepEqual(
    fixture.events.filter((event) =>
      event.type === 'history_reduced' && event.id === 'turn-usage-hangs'),
    [{
      type: 'history_reduced',
      id: 'turn-usage-hangs',
      omittedMessages: 0,
      shortenedMessages: 2,
      reason: 'context_preflight_unavailable',
    }],
    'usage-control recovery retains the unavailable-preflight reason',
  )
})

test('Vertex skips its advertised but unanswered context control on a resumed turn', async (t) => {
  const fixture = startFixture(t, 'vertex-usage-hangs', { authMode: 'vertex' })
  const ready = await waitFor(
    () => fixture.events.find((event) => event.type === 'ready'),
    'Vertex ready',
    fixture,
  )
  assert.equal(ready.auth, 'vertex')
  sendSmallRecoverableTurn(fixture, 'turn-vertex-usage-hangs')

  const terminal = await waitFor(
    () => fixture.events.find((event) => event.id === 'turn-vertex-usage-hangs'
      && (event.type === 'done' || event.type === 'error')),
    'Vertex turn without context-control timeout',
    fixture,
  )
  assert.deepEqual(terminal, { type: 'done', id: 'turn-vertex-usage-hangs' })

  const records = fixture.records().filter((line) => line.startsWith('{')).map(JSON.parse)
  assert.deepEqual(
    records.filter((entry) => entry.kind === 'query').map((entry) => ({
      resume: entry.resume,
      abortAlreadySignaled: entry.abortAlreadySignaled,
    })),
    [{ resume: 'overfull-session', abortAlreadySignaled: false }],
  )
  assert.deepEqual(
    records.filter((entry) => entry.kind === 'prompt').map(({ attempt, text }) => ({
      attempt, text,
    })),
    [{ attempt: 1, text: 'answer this exact current prompt' }],
  )
  assert.equal(
    records.filter((entry) => entry.kind === 'context-usage').length,
    0,
    'Vertex must not invoke the control method that its engine never answers',
  )
  assert.equal(
    fixture.events.some((event) => event.type === 'session_invalidated'
      && event.id === 'turn-vertex-usage-hangs'),
    false,
  )
  assert.equal(
    fixture.events.some((event) => event.type === 'history_reduced'
      && event.id === 'turn-vertex-usage-hangs'),
    false,
  )
  assert.equal(
    fixture.events.some((event) => event.type === 'info'
      && /context usage was unavailable/i.test(event.message || '')),
    false,
  )
})

test('Vertex background invalid_rapt ready publishes the normalized lane failure', async (t) => {
  const fixture = startFixture(t, 'vertex-rapt-ready', { authMode: 'vertex' })
  const failedReady = await waitFor(
    () => fixture.events.find((event) => event.type === 'ready'
      && event.accountStatus === 'disconnected'),
    'Vertex disconnected ready',
    fixture,
  )
  assert.equal(failedReady.loggedIn, false)
  assert.deepEqual(failedReady.accountFailure, {
    errorKind: 'authentication',
    provider: 'anthropic',
    access: 'claude_vertex',
    message: 'Your organization requires you to sign in to Google again. Reauthenticate with Google to continue using Google Vertex.',
    providerError: {
      providerType: 'credential_reauth_required',
      status: 400,
      code: 'invalid_rapt',
    },
    reconnectRequired: true,
  })

  const beforeReload = fixture.events.length
  fixture.child.stdin.write(`${JSON.stringify({
    type: 'account_reload',
    id: 'vertex-rapt-reload',
  })}\n`)
  const reload = await waitFor(
    () => fixture.events.find((event) => event.type === 'account_reload_ok'
      && event.id === 'vertex-rapt-reload'),
    'Vertex RAPT account reload',
    fixture,
  )
  assert.equal(reload.loggedIn, false)
  const afterReload = fixture.events.slice(beforeReload)
  const reloadReadyIndex = afterReload.findIndex((event) => event.type === 'ready'
    && event.accountStatus === 'disconnected')
  const reloadOKIndex = afterReload.findIndex((event) => event === reload)
  assert.ok(reloadReadyIndex >= 0 && reloadReadyIndex < reloadOKIndex,
    'the account-instance ready snapshot must publish before its reload acknowledgement')
  assert.deepEqual(afterReload[reloadReadyIndex].accountFailure, failedReady.accountFailure)
})

test('Vertex turn-preflight invalid_rapt terminal precedes disconnect publication', async (t) => {
  const fixture = startFixture(t, 'vertex-turn-rapt', { authMode: 'vertex' })
  await waitFor(
    () => fixture.events.find((event) => event.type === 'ready'
      && event.accountStatus === 'verified'),
    'initial verified Vertex ready',
    fixture,
  )

  const turnID = 'turn-vertex-rapt'
  const turnStart = fixture.events.length
  sendFirstMessageTurn(fixture, turnID)
  const terminal = await waitFor(
    () => fixture.events.find((event) => event.id === turnID
      && event.type === 'error'),
    'Vertex invalid_rapt terminal',
    fixture,
  )
  await waitFor(
    () => fixture.events.slice(turnStart).find((event) => event.type === 'ready'
      && event.accountStatus === 'disconnected'),
    'Vertex disconnected ready after turn terminal',
    fixture,
  )
  await waitFor(
    () => fixture.events.slice(turnStart).find((event) => event.type === 'model_catalog'
      && event.models?.length === 0),
    'cleared Vertex catalog after turn terminal',
    fixture,
  )

  const timeline = fixture.events.slice(turnStart)
  const startedIndex = timeline.findIndex((event) => event.type === 'turn_started'
    && event.id === turnID)
  const authenticationErrors = timeline.filter((event) => event.type === 'error'
    && event.id === turnID && event.errorKind === 'authentication')
  assert.equal(authenticationErrors.length, 1)
  assert.equal(authenticationErrors[0], terminal)
  const terminalIndex = timeline.indexOf(terminal)
  const disconnectedIndex = timeline.findIndex((event) => event.type === 'ready'
    && event.accountStatus === 'disconnected')
  const clearedCatalogIndex = timeline.findIndex((event) => event.type === 'model_catalog'
    && event.models?.length === 0)
  assert.ok(startedIndex >= 0 && startedIndex < terminalIndex,
    'accepted turn ownership must publish before its terminal')
  assert.ok(terminalIndex < disconnectedIndex,
    'the terminal must relinquish app-side turn ownership before reconnect becomes available')
  assert.ok(terminalIndex < clearedCatalogIndex,
    'the terminal must publish before the rejected account clears its catalog')
  assert.deepEqual(terminal.providerError, {
    providerType: 'credential_reauth_required',
    status: 400,
    code: 'invalid_rapt',
  })

  // Reuse the exact turn ID. A second turn_started proves both active and accepted daemon
  // ownership were retired after the first terminal rather than remaining invisibly busy.
  sendFirstMessageTurn(fixture, turnID)
  await waitFor(
    () => fixture.events.filter((event) => event.type === 'turn_started'
      && event.id === turnID).length === 2,
    'reaccepted turn after Vertex authentication failure',
    fixture,
  )
  await waitFor(
    () => fixture.events.find((event) => event.type === 'done' && event.id === turnID),
    'successful turn after refreshed Vertex preflight',
    fixture,
  )
  assert.equal(fixture.events.some((event) => event.type === 'control_error'
    && event.id === turnID && /duplicate active turn id/i.test(event.message || '')), false)
  assert.equal(fixture.events.filter((event) => event.type === 'error'
    && event.id === turnID && event.errorKind === 'authentication').length, 1)
})

test('Vertex keeps its session when a failed compaction recovers on retry', async (t) => {
  const fixture = startFixture(t, 'recover', { authMode: 'vertex' })
  await waitFor(() => fixture.events.find((event) => event.type === 'ready'), 'Vertex ready', fixture)
  sendOverfullTurn(fixture, 'turn-vertex-compaction-failed')

  const terminal = await waitFor(
    () => fixture.events.find((event) => event.id === 'turn-vertex-compaction-failed'
      && (event.type === 'done' || event.type === 'error')),
    'Vertex bounded compaction recovery',
    fixture,
  )
  assert.deepEqual(terminal, { type: 'done', id: 'turn-vertex-compaction-failed' })

  const records = fixture.records()
  const structured = records.filter((line) => line.startsWith('{')).map(JSON.parse)
  assert.deepEqual(
    structured.filter((entry) => entry.kind === 'query').map((entry) => entry.resume),
    ['overfull-session', 'overfull-session'],
    'Vertex is where this cost the most sessions, so it must keep them too',
  )
  assert.equal(structured.filter((entry) => entry.kind === 'context-usage').length, 0)
  // The cascade guard is intact: the oversized request is still never submitted.
  assert.equal(records.includes('VERTEX_REQUEST_SUBMITTED_AFTER_FAILED_COMPACTION'), false)
  const replay = structured.find((entry) => entry.kind === 'prompt' && entry.attempt === 2)?.text
  assert.ok(replay.endsWith('answer this exact current prompt'))
  assert.ok(Buffer.byteLength(replay, 'utf8') < 170_000)
})

test('fresh Vertex prompts keep the unknown-usage input bound without calling context control', async (t) => {
  const fixture = startFixture(t, 'fresh-too-large', { authMode: 'vertex' })
  await waitFor(() => fixture.events.find((event) => event.type === 'ready'), 'Vertex ready', fixture)
  sendHugeFreshTurn(fixture, 'turn-vertex-huge-fresh')

  const terminal = await waitFor(
    () => fixture.events.find((event) => event.id === 'turn-vertex-huge-fresh'
      && (event.type === 'done' || event.type === 'error')),
    'fresh Vertex prompt bound',
    fixture,
  )
  assert.equal(terminal.type, 'error')
  assert.equal(terminal.errorKind, 'context_limit')
  assert.equal(terminal.providerError?.code, 'prompt_preflight_limit')

  const records = fixture.records().filter((line) => line.startsWith('{')).map(JSON.parse)
  assert.equal(records.filter((entry) => entry.kind === 'context-usage').length, 0)
  assert.equal(
    records.filter((entry) => entry.kind === 'prompt').length,
    0,
    'the exact oversized prompt must be rejected before Vertex input delivery',
  )
})
