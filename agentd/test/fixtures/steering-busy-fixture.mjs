#!/usr/bin/env node
import fs from 'node:fs'
import readline from 'node:readline'

const emit = (event) => process.stdout.write(`${JSON.stringify(event)}\n`)
const wait = (milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds))
const logPath = process.env.MECHANICIAN_FIXTURE_LOG
const record = (event) => {
  if (logPath) fs.appendFileSync(logPath, `${JSON.stringify(event)}\n`)
}

let activeTurn = null
let terminal = false

emit({
  type: 'ready', mode: 'sdk', provider: 'codex', auth: 'subscription', loggedIn: true,
  planType: 'pro', cwd: process.env.MECHANICIAN_CWD || process.cwd(),
})
emit({ type: 'allowlist', tools: [] })
emit({
  type: 'model_catalog', scope: '', models: [{
    id: 'gpt-5.6-steering-fixture', label: 'GPT-5.6 Steering Fixture', isDefault: true,
    efforts: ['low', 'medium', 'high', 'xhigh', 'max'], capabilities: ['effort'],
  }],
})

async function runTurn(id) {
  activeTurn = id
  terminal = false
  emit({ type: 'turn_started', id })
  emit({ type: 'session', id, sessionId: 'codex-tools:steering-fixture-thread' })
  emit({ type: 'status', id, status: 'working' })
  emit({ type: 'delta', id, text: 'The fixture is working. Send guidance while this turn remains active. ' })
  await wait(600000)
  if (activeTurn === id && !terminal) {
    terminal = true
    emit({ type: 'done', id })
  }
}

const rl = readline.createInterface({ input: process.stdin })
rl.on('line', (line) => {
  let request
  try { request = JSON.parse(line) } catch { return }
  record(request)
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
          id: 'gpt-5.6-steering-fixture', label: 'GPT-5.6 Steering Fixture', isDefault: true,
          efforts: ['low', 'medium', 'high', 'xhigh', 'max'], capabilities: ['effort'],
        }],
      })
      break
    case 'send': void runTurn(request.id); break
    case 'steer':
      if (activeTurn === request.turnId && !terminal) {
        emit({
          type: 'steer_ack', id: request.turnId, turnId: request.turnId,
          steerId: request.steerId,
        })
        emit({ type: 'delta', id: request.turnId, text: `Guidance received: ${request.prompt} ` })
      } else {
        emit({
          type: 'steer_rejected', id: request.turnId, turnId: request.turnId,
          steerId: request.steerId,
        })
      }
      break
    case 'interrupt':
      terminal = true
      emit({ type: 'done', id: request.turnId || request.id, interrupted: true })
      break
    case 'reset': emit({ type: 'reset_ok', id: request.id }); break
    default: break
  }
})
