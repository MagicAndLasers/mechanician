// Running a scheduled task on any provider agentd supports, by driving agentd itself.
//
// WHY THIS AND NOT A SECOND RUNTIME. ambientd runs Claude through the Agent SDK directly, which is
// fine for exactly one provider. Every other lane already has a complete, exercised implementation
// inside agentd — the OpenAI Responses agent loop, the Codex app-server, their tool executors,
// their error normalization. Re-implementing any of that in ambientd would duplicate hundreds of
// lines and guarantee the two copies drift; the scheduler would slowly become a second, worse
// runtime.
//
// agentd is already a headless daemon speaking NDJSON over stdio. So the scheduler spawns one,
// sends a turn, and reads events until the turn ends. The unattended concerns that have no wire
// representation — nobody to answer a permission prompt, tools that need a foreground session —
// are handled by MECHANICIAN_UNATTENDED, which narrows agentd's tool surface and makes its
// authorization decide instead of prompt.
//
// Everything the daemon is asked for is per-turn, so one process serves one run and exits.

import { spawn } from 'node:child_process'
import fs from 'node:fs'
import path from 'node:path'
import { randomUUID } from 'node:crypto'
import { fileURLToPath } from 'node:url'

/// Provider/auth pair for a lane, matching what AgentdRuntime passes for an interactive window.
/// A lane absent from this map has no unattended implementation and must not be scheduled.
const LANE_ROUTES = {
  openai_api: { provider: 'openai', auth: 'apikey' },
  anthropic_api: { provider: 'anthropic', auth: 'apikey' },
  claude_vertex: { provider: 'anthropic', auth: 'vertex' },
}

const MCP_PENDING_BLOCK_REASON =
  'An MCP connection change for this provider still needs a fresh tool check in Mechanician. '
  + 'Open Mechanician, finish activating the connection, then retry this scheduled task.'
const MCP_STATE_UNREADABLE_BLOCK_REASON =
  'Mechanician could not verify this provider’s pending MCP connection state, so scheduled work '
  + 'was held. Open Mechanician and repair the connection state before retrying this task.'

function pendingBoundaryForAccess(ledger, access) {
  // These ledgers are optional for compatibility with releases that predate the handoff. A
  // present-but-malformed ledger is different: absence is known-empty, while malformed bytes
  // cannot prove that this exact provider route has no credential mutation in flight.
  if (ledger == null) return false
  if (typeof ledger !== 'object' || Array.isArray(ledger)) return null
  const byAccess = ledger.byAccess
  if (!byAccess || typeof byAccess !== 'object' || Array.isArray(byAccess)) return null
  if (!Object.prototype.hasOwnProperty.call(byAccess, access)) return false
  const entries = byAccess[access]
  if (!Array.isArray(entries)) return null
  return entries.length > 0
}

/// Derive only a Boolean-style, non-secret gate from extensions.json. Server names, request IDs,
/// account identities, and credential metadata never enter the scheduled run report. Other access
/// lanes are deliberately ignored: a pending Anthropic boundary must not stop an OpenAI task.
export function mcpBlockedReasonFromExtensions(payload, access) {
  if (!payload || typeof payload !== 'object' || Array.isArray(payload)
      || typeof access !== 'string' || !access) {
    return MCP_STATE_UNREADABLE_BLOCK_REASON
  }
  const readiness = pendingBoundaryForAccess(payload.pendingMCPReadiness, access)
  const authorization = pendingBoundaryForAccess(payload.pendingMCPAuthorizations, access)
  if (readiness === null || authorization === null) return MCP_STATE_UNREADABLE_BLOCK_REASON
  return readiness || authorization ? MCP_PENDING_BLOCK_REASON : null
}

/// Read a fresh atomic sidecar snapshot for each run. ENOENT is an older/pristine installation and
/// therefore has no persisted boundary; every other read/decode uncertainty fails closed before a
/// provider child can be spawned.
export function readMcpBlockedReason(
  extensionsFile,
  access,
  { readFile = fs.readFileSync } = {},
) {
  let bytes
  try {
    bytes = readFile(extensionsFile, 'utf8')
  } catch (error) {
    return error?.code === 'ENOENT' ? null : MCP_STATE_UNREADABLE_BLOCK_REASON
  }
  try {
    return mcpBlockedReasonFromExtensions(JSON.parse(String(bytes)), access)
  } catch {
    return MCP_STATE_UNREADABLE_BLOCK_REASON
  }
}

export function laneRoute(access) {
  return Object.hasOwn(LANE_ROUTES, access) ? LANE_ROUTES[access] : null
}

export function isLaneRunnable(access) {
  return Boolean(laneRoute(access))
}

/// Split a stdout chunk stream into NDJSON values, tolerating partial lines. A malformed line is
/// skipped rather than failing the run: agentd also logs human-readable diagnostics on stderr, and
/// one unparseable line must not lose a completed turn.
export function createLineReader(onValue) {
  let buffer = ''
  return (chunk) => {
    buffer += chunk
    let index = buffer.indexOf('\n')
    while (index >= 0) {
      const line = buffer.slice(0, index).trim()
      buffer = buffer.slice(index + 1)
      if (line) {
        try { onValue(JSON.parse(line)) } catch {}
      }
      index = buffer.indexOf('\n')
    }
  }
}

function artifactFromAgentdEvent(
  event,
  { readFile = fs.readFileSync, removeFile = fs.unlinkSync } = {},
) {
  let source = typeof event.source === 'string' ? event.source : null
  if (typeof event.sourcePath === 'string' && event.sourcePath) {
    // `sourcePath` is a one-shot handoff owned by agentd. Consume it exactly as the interactive
    // Swift client does, and remove it even when the read fails so scheduled runs cannot leak one
    // temporary file for every large artifact they produce.
    try {
      source = String(readFile(event.sourcePath, 'utf8'))
    } catch {
      // If a malformed event supplied both forms, retain the inline source as a safe fallback.
    } finally {
      try { removeFile(event.sourcePath) } catch {}
    }
  }
  if (typeof event.artifactType !== 'string' || typeof event.title !== 'string'
      || source === null) return null
  return { title: event.title, type: event.artifactType, source }
}

/// Fold one agentd event into the accumulating run state. The artifact case consumes agentd's
/// one-shot `sourcePath`; the injectable file operations keep that protocol edge independently
/// testable without spawning anything.
///
/// `state` is `{ text, artifacts, error, finished, interrupted }`.
export function applyAgentdEvent(
  state,
  event,
  { permissionMode, readFile, removeFile } = {},
) {
  const next = state
  switch (event?.type) {
    case 'delta':
      if (typeof event.text === 'string') next.text += event.text
      break
    case 'artifact':
      {
        const artifact = artifactFromAgentdEvent(event, { readFile, removeFile })
        if (artifact) next.artifacts.push(artifact)
      }
      break
    case 'permission_request':
      // Unattended agentd decides from policy and never asks, so a prompt reaching here means a
      // lane whose adapter still prompts. Answer deny so the turn proceeds instead of hanging, and
      // record it — silently denying would look like the model simply chose not to act.
      {
        const allow = permissionMode === 'bypassPermissions'
        if (!allow) next.permissionDenials.push(event.name || 'a tool')
        next.reply = {
          type: 'permission_response', id: event.id, permissionId: event.permissionId,
          responseId: event.permissionId, allow, always: false,
          ...(!allow ? { message: 'Scheduled tasks cannot ask for permission.' } : {}),
        }
      }
      break
    case 'question_request':
      next.reply = {
        type: 'question_response', id: event.id, reqId: event.reqId,
        responseId: event.reqId, answers: {},
      }
      break
    case 'unattended_denied':
      // A capability the task reached for and could not have. Recorded so the run report can name
      // it — the user cannot otherwise tell "the agent chose not to" from "the agent was refused".
      if (event.name && !next.blockedTools.includes(event.name)) next.blockedTools.push(event.name)
      break
    case 'error':
      next.error = event.message || 'The provider run failed.'
      next.finished = true
      break
    case 'done':
      if (event.interrupted) next.interrupted = true
      next.finished = true
      break
    default:
      break
  }
  return next
}

export function newRunState() {
  return {
    text: '', artifacts: [], permissionDenials: [], blockedTools: [],
    error: null, finished: false, interrupted: false, reply: null,
  }
}

/**
 * Run one unattended turn through a freshly spawned agentd.
 *
 * @returns {Promise<{text:string, artifacts:object[], error:string|null, interrupted:boolean}>}
 */
export async function runTurnViaAgentd({
  access, prompt, cwd, model, effort, permissionMode, timeoutMs = 15 * 60_000,
  projectInstructions = null,
  mcpBlockedReason = null,
  env = process.env, log = () => {}, spawnFn = spawn, agentdPath, nodePath,
}) {
  const route = laneRoute(access)
  if (!route) throw new Error(`No unattended runtime for ${access}.`)
  const blocked = typeof mcpBlockedReason === 'string' ? mcpBlockedReason.trim() : ''
  if (blocked) throw new Error(blocked)

  const script = agentdPath
    || path.join(path.dirname(fileURLToPath(import.meta.url)), 'agentd.mjs')
  const childEnv = {
    ...env,
    MECHANICIAN_PROVIDER: route.provider,
    MECHANICIAN_AUTH: route.auth,
    MECHANICIAN_UNATTENDED: '1',
    MECHANICIAN_CWD: cwd || env.HOME || process.cwd(),
  }
  // agentd resolves the lane's credential from the Keychain itself, exactly as it does for a
  // window. The scheduler deliberately does not read or forward provider secrets.

  const child = spawnFn(nodePath || process.execPath, [script], {
    cwd: cwd || undefined,
    env: childEnv,
    stdio: ['pipe', 'pipe', 'pipe'],
  })

  const state = newRunState()
  const turnId = randomUUID().toUpperCase()

  return await new Promise((resolve) => {
    let settled = false
    const finish = () => {
      if (settled) return
      settled = true
      clearTimeout(timer)
      try { child.kill('SIGTERM') } catch {}
      resolve({
        text: state.text,
        artifacts: state.artifacts,
        error: state.error,
        interrupted: state.interrupted,
        permissionDenials: state.permissionDenials,
        blockedTools: state.blockedTools,
      })
    }
    const timer = setTimeout(() => {
      state.error = state.error || 'The scheduled run exceeded its time limit.'
      finish()
    }, timeoutMs)

    const write = (value) => {
      try { child.stdin.write(`${JSON.stringify(value)}\n`) } catch {}
    }

    let sent = false
    const read = createLineReader((event) => {
      // The turn is only accepted once the lane reports ready; sending earlier races the daemon's
      // credential and runtime bring-up.
      if (event?.type === 'ready' && !sent) {
        sent = true
        const request = {
          type: 'send', id: turnId, prompt, cwd,
          model: model || undefined, effort: effort || 'high',
          permissionMode: permissionMode === 'bypassPermissions' ? 'bypassPermissions' : 'default',
        }
        if (typeof projectInstructions === 'string' && projectInstructions.trim()) {
          request.projectInstructions = projectInstructions.trim()
        }
        write(request)
        return
      }
      // Interactive Swift consumes this handoff into the canonical transcript. Scheduled runs do
      // not retain provider context summaries, so remove the daemon-owned payload immediately
      // rather than leaking one temp file per unattended compaction.
      if (event?.type === 'compaction_summary' && typeof event.summaryPath === 'string') {
        try { fs.unlinkSync(event.summaryPath) } catch {}
      }
      // Interactive Swift consumes Codex-generated image handoffs into durable transcript media.
      // Scheduled runs retain only their textual outcome, so they must discard the same one-shot
      // payload rather than leaking an orphaned temporary image.
      if (event?.type === 'tool_result' && typeof event.generatedImagePath === 'string') {
        try { fs.unlinkSync(event.generatedImagePath) } catch {}
      }
      applyAgentdEvent(state, event, { permissionMode })
      if (state.reply) { write(state.reply); state.reply = null }
      if (state.finished) finish()
    })

    child.stdout.setEncoding('utf8')
    child.stdout.on('data', read)
    child.stderr.setEncoding('utf8')
    child.stderr.on('data', (chunk) => {
      const text = String(chunk).trim()
      if (text) log(`[${access}] ${text.split('\n').slice(-1)[0].slice(0, 300)}`)
    })
    child.on('error', (err) => {
      state.error = `Could not start the ${access} runtime: ${err?.message || err}`
      finish()
    })
    child.on('exit', (code) => {
      // An exit before `done` is a failure the turn never reported; without this the run would
      // hang until its timeout with no explanation.
      if (!state.finished && !state.text) {
        state.error = state.error || `The ${access} runtime exited (code ${code}) before finishing.`
      }
      finish()
    })
  })
}
