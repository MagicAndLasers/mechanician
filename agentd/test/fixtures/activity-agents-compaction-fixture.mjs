#!/usr/bin/env node
import readline from 'node:readline'

const emit = (event) => process.stdout.write(`${JSON.stringify(event)}\n`)
const wait = (milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds))

emit({
  type: 'ready', mode: 'sdk', provider: 'codex', auth: 'subscription', loggedIn: true,
  planType: 'pro', cwd: process.env.MECHANICIAN_CWD || process.cwd(),
})
emit({ type: 'allowlist', tools: [] })
emit({
  type: 'model_catalog', scope: '', models: [{
    id: 'gpt-5.6-fixture', label: 'GPT-5.6 Fixture', isDefault: true,
    efforts: ['low', 'medium', 'high', 'xhigh', 'max'], capabilities: ['effort'],
  }],
})

async function runTurn(id) {
  emit({ type: 'turn_started', id })
  emit({ type: 'session', id, sessionId: 'codex-tools:fixture-thread' })

  for (let index = 1; index <= 3; index += 1) {
    const toolUseId = `command-${index}`
    emit({
      type: 'tool_use', id, toolUseId, name: 'Bash',
      input: { command: `printf 'activity command ${index}\\n'` },
    })
    await wait(180)
    emit({
      type: 'tool_result', id, toolUseId, status: index === 2 ? 'error' : 'success',
      result: index === 2
        ? 'fixture command failed with exit code 2'
        : `activity command ${index}\n`,
    })
    emit({
      type: 'usage', id,
      input: 900 + index * 180,
      cachedInput: 600 + index * 120,
      output: 70 + index * 35,
      reasoningOutput: index * 12,
    })
  }
  emit({
    type: 'context_usage', id, contextTokens: 42_000, contextWindow: 200_000,
    model: 'gpt-5.6-fixture',
  })

  const children = [
    {
      taskId: 'fixture-architecture', toolUseId: 'fixture-spawn-architecture',
      description: 'Map the application architecture and major data flows',
      summary: 'Tracing bridge and store ownership', lastToolName: 'Read',
    },
    {
      taskId: 'fixture-tests', toolUseId: 'fixture-spawn-tests',
      description: 'Inspect the test strategy and identify coverage risks',
      summary: 'Reviewing the Swift and Node test suites', lastToolName: 'Grep',
    },
    {
      taskId: 'fixture-performance', toolUseId: 'fixture-spawn-performance',
      description: 'Find performance-sensitive paths and measurable improvements',
      summary: 'Sampling rendering and event hot paths', lastToolName: 'Bash',
    },
  ]
  // Exercise the real provisional→authoritative identity race for the first child. The final
  // combined update collapses its card, and the timeline must collapse the two sampled ids too.
  emit({
    type: 'workflow_update', id, phase: 'started',
    taskId: children[0].toolUseId, toolUseId: children[0].toolUseId,
    taskType: 'codex_subagent', subagentType: 'general-purpose',
    description: children[0].description, summary: 'Starting architecture pass',
    status: 'running',
  })
  await wait(100)
  emit({
    type: 'workflow_update', id, phase: 'started', taskId: children[0].taskId,
    taskType: 'codex_subagent', subagentType: 'general-purpose',
    description: children[0].description, summary: children[0].summary,
    status: 'running',
  })
  await wait(100)
  for (const [index, child] of children.entries()) {
    emit({
      type: 'workflow_update', id, phase: index === 0 ? 'progress' : 'started',
      taskId: child.taskId, toolUseId: child.toolUseId,
      taskType: 'codex_subagent', subagentType: 'general-purpose',
      description: child.description, summary: child.summary,
      lastToolName: child.lastToolName, status: 'running',
      usage: {
        totalTokens: 840 + index * 210,
        inputTokens: 620 + index * 120,
        cachedInputTokens: 300 + index * 40,
        outputTokens: 220 + index * 90,
      },
    })
  }
  await wait(500)
  emit({
    type: 'context_usage', id, contextTokens: 182_000, contextWindow: 200_000,
    model: 'gpt-5.6-fixture',
  })
  emit({ type: 'status', id, status: 'compacting' })
  await wait(650)
  emit({ type: 'status', id, status: '' })
  emit({
    type: 'compact_boundary', id, trigger: 'auto', preTokens: 182000, postTokens: 51000,
  })
  emit({
    type: 'context_usage', id, contextTokens: 51_000, contextWindow: 200_000,
    model: 'gpt-5.6-fixture',
  })

  const paragraphs = [
    'The Activity group, compaction card, and child agent are now live.',
    'This response streams in bounded chunks so its native row geometry can be observed.',
    'The top of this text box should move only as genuinely required to keep new output visible.',
    'It must never reverse direction, overlap the Activity detail, or disappear beneath another row.',
    'The final layout should remain contiguous and stable after the child completes.',
  ]
  for (const paragraph of paragraphs) {
    for (const word of paragraph.split(' ')) {
      emit({ type: 'delta', id, text: `${word} ` })
      await wait(55)
    }
    emit({ type: 'delta', id, text: '\n\n' })
    await wait(220)
  }
  emit({
    type: 'context_usage', id, contextTokens: 68_000, contextWindow: 200_000,
    model: 'gpt-5.6-fixture',
  })

  await wait(4000)
  for (const [index, child] of children.entries()) {
    emit({
      type: 'workflow_update', id, phase: 'notification',
      taskId: child.taskId, toolUseId: child.toolUseId,
      taskType: 'codex_subagent', subagentType: 'general-purpose',
      description: child.description, summary: 'Verification complete',
      status: 'completed',
      usage: {
        totalTokens: 1280 + index * 180,
        inputTokens: 310 + index * 70,
        cachedInputTokens: 140 + index * 30,
        outputTokens: 130 + index * 55,
      },
    })
  }
  emit({ type: 'done', id })
}

const rl = readline.createInterface({ input: process.stdin })
rl.on('line', (line) => {
  let request
  try { request = JSON.parse(line) } catch { return }
  switch (request.type) {
    case 'ping': emit({ type: 'pong', id: request.id }); break
    case 'load':
      emit({
        type: 'loaded', id: request.id, sessionId: request.sessionId || null,
        cwd: request.cwd || process.env.MECHANICIAN_CWD || process.cwd(),
      })
      break
    case 'model_catalog':
      emit({
        type: 'model_catalog', id: request.id, scope: request.scope || '', models: [{
          id: 'gpt-5.6-fixture', label: 'GPT-5.6 Fixture', isDefault: true,
          efforts: ['low', 'medium', 'high', 'xhigh', 'max'], capabilities: ['effort'],
        }],
      })
      break
    case 'send': void runTurn(request.id); break
    case 'steer':
      emit({ type: 'steer_ack', id: request.turnId || request.id, steerId: request.steerId })
      break
    case 'interrupt': emit({ type: 'done', id: request.id, interrupted: true }); break
    case 'reset': emit({ type: 'reset_ok', id: request.id }); break
    default: break
  }
})
