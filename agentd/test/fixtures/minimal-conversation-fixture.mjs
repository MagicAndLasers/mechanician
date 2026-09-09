#!/usr/bin/env node
// Deterministic Stage A seed for the smallest retained Conversation shape. Capture supplies the
// observation clock, so this generator contains no wall-clock calls or machine-local values.
// Producer/profile metadata is intentionally absent: corpus case 1 remains partial until the
// canonical model decides and captures that fact instead of inventing it here.
import readline from 'node:readline'

const emit = (event) => process.stdout.write(`${JSON.stringify(event)}\n`)

emit({
  type: 'ready', mode: 'fixture', provider: 'mechanician-fixture', auth: 'none',
  loggedIn: true, cwd: '',
})
emit({ type: 'allowlist', tools: [] })
emit({ type: 'model_catalog', scope: '', models: [] })

const rl = readline.createInterface({ input: process.stdin })
rl.on('line', (line) => {
  let request
  try { request = JSON.parse(line) } catch { return }
  if (request.type !== 'send') return
  emit({ type: 'turn_started', id: request.id })
  emit({ type: 'session', id: request.id, sessionId: 'PRIVATE-RESUME-HANDLE-MUST-NOT-SURVIVE' })
  emit({ type: 'delta', id: request.id, text: 'Minimal retained response.' })
  emit({ type: 'done', id: request.id })
})
