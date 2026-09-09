import { createHash } from 'node:crypto'

const TERMINAL_TURN_STATUSES = new Set(['completed', 'failed', 'interrupted'])
export const CODEX_LIFECYCLE_PHASES = Object.freeze([
  'queued',
  'providerStarting',
  'providerActive',
  'waitingForApproval',
  'waitingForUserInput',
  'reconciling',
  'completed',
  'failed',
  'interrupted',
  'recoverableOrphan',
])
const CODEX_LIFECYCLE_PHASE_SET = new Set(CODEX_LIFECYCLE_PHASES)
const CODEX_TERMINAL_PHASES = new Set([
  'completed', 'failed', 'interrupted', 'recoverableOrphan',
])
const CODEX_RESUMABLE_PHASES = new Set([
  'providerActive', 'waitingForApproval', 'waitingForUserInput',
])
const CODEX_LIFECYCLE_TRANSITIONS = new Map([
  [null, new Set(['queued'])],
  ['queued', new Set(['queued', 'providerStarting', 'failed', 'interrupted'])],
  ['providerStarting', new Set([
    'providerStarting', 'providerActive', 'waitingForApproval', 'waitingForUserInput',
    'reconciling', 'completed', 'failed', 'interrupted', 'recoverableOrphan',
  ])],
  ['providerActive', new Set([
    'providerActive', 'waitingForApproval', 'waitingForUserInput', 'reconciling',
    'completed', 'failed', 'interrupted', 'recoverableOrphan',
  ])],
  ['waitingForApproval', new Set([
    'providerActive', 'waitingForApproval', 'waitingForUserInput', 'reconciling',
    'completed', 'failed', 'interrupted', 'recoverableOrphan',
  ])],
  ['waitingForUserInput', new Set([
    'providerActive', 'waitingForApproval', 'waitingForUserInput', 'reconciling',
    'completed', 'failed', 'interrupted', 'recoverableOrphan',
  ])],
  ['reconciling', new Set([
    'providerActive', 'waitingForApproval', 'waitingForUserInput', 'reconciling',
    'completed', 'failed', 'interrupted', 'recoverableOrphan',
  ])],
])
const TRACE_DETAIL_KEYS = Object.freeze([
  'reason',
  'method',
  'providerStatus',
  'threadStatus',
  'activeFlags',
  'failureCount',
  'errorCode',
  'errorMethod',
  'result',
  'restartReason',
  'requestTimeoutMs',
])

function boundedTraceString(value, maximum = 160) {
  return typeof value === 'string' && value
    ? value.slice(0, maximum)
    : undefined
}

function traceDetailValue(key, value) {
  if (key === 'activeFlags') {
    if (!Array.isArray(value)) return undefined
    return value
      .filter((candidate) => typeof candidate === 'string')
      .slice(0, 8)
      .map((candidate) => candidate.slice(0, 64))
  }
  if (key === 'failureCount' || key === 'requestTimeoutMs') {
    return Number.isFinite(value) ? value : undefined
  }
  if (key === 'errorCode') {
    if (typeof value === 'number' && Number.isFinite(value)) return value
    return boundedTraceString(value)
  }
  return boundedTraceString(value, key === 'restartReason' ? 512 : 160)
}

function normalizedThreadStatus(status) {
  if (!status || typeof status !== 'object' || typeof status.type !== 'string') {
    return { type: null, activeFlags: [] }
  }
  return {
    type: status.type,
    activeFlags: Array.isArray(status.activeFlags)
      ? status.activeFlags.filter((flag) => typeof flag === 'string')
      : [],
  }
}

export function codexLifecycleStateForThreadStatus(status, fallback = 'providerActive') {
  const normalized = normalizedThreadStatus(status)
  if (normalized.type !== 'active') return fallback
  if (normalized.activeFlags.includes('waitingOnApproval')) return 'waitingForApproval'
  if (normalized.activeFlags.includes('waitingOnUserInput')) return 'waitingForUserInput'
  return 'providerActive'
}

export function classifyCodexThreadRead(result, expectedTurnId) {
  const thread = result?.thread
  if (!thread || typeof thread !== 'object' ||
      typeof expectedTurnId !== 'string' || !expectedTurnId) {
    return { kind: 'invalid', reason: 'missing_thread_or_turn_identity' }
  }

  const status = normalizedThreadStatus(thread.status)
  if (!Array.isArray(thread.turns)) {
    return {
      kind: 'invalid',
      reason: 'turns_not_loaded',
      threadStatus: status.type,
      activeFlags: status.activeFlags,
    }
  }

  const turn = thread.turns.find((candidate) => candidate?.id === expectedTurnId) || null
  if (turn) {
    if (TERMINAL_TURN_STATUSES.has(turn.status)) {
      return {
        kind: 'terminal',
        turn,
        threadStatus: status.type,
        activeFlags: status.activeFlags,
      }
    }
    if (status.type === 'systemError') {
      return {
        kind: 'systemError',
        turn,
        threadStatus: status.type,
        activeFlags: status.activeFlags,
      }
    }
    if (turn.status === 'inProgress' && status.type === 'active') {
      return {
        kind: 'active',
        turn,
        threadStatus: status.type,
        activeFlags: status.activeFlags,
        lifecycleState: codexLifecycleStateForThreadStatus(thread.status),
      }
    }
    if (turn.status === 'inProgress') {
      return {
        kind: 'inconsistent',
        reason: 'in_progress_turn_on_inactive_thread',
        turn,
        threadStatus: status.type,
        activeFlags: status.activeFlags,
      }
    }
    return {
      kind: 'invalid',
      reason: 'unknown_turn_status',
      turn,
      threadStatus: status.type,
      activeFlags: status.activeFlags,
    }
  }

  if (status.type === 'active') {
    return {
      kind: 'missingActive',
      threadStatus: status.type,
      activeFlags: status.activeFlags,
      lifecycleState: codexLifecycleStateForThreadStatus(thread.status),
    }
  }
  if (status.type === 'systemError') {
    return {
      kind: 'systemError',
      threadStatus: status.type,
      activeFlags: status.activeFlags,
    }
  }
  if (status.type === 'idle' || status.type === 'notLoaded') {
    return {
      kind: 'orphaned',
      threadStatus: status.type,
      activeFlags: status.activeFlags,
    }
  }
  return {
    kind: 'invalid',
    reason: 'unknown_thread_status',
    threadStatus: status.type,
    activeFlags: status.activeFlags,
  }
}

function codexTerminalPhase(status, interrupted = false) {
  if (interrupted || status === 'interrupted') return 'interrupted'
  if (status === 'completed') return 'completed'
  return 'failed'
}

function boundedPositiveInteger(value, fallback) {
  return Number.isInteger(value) && value > 0 ? value : fallback
}

/// Pure lifecycle authority for one accepted Codex turn.
///
/// The daemon owns I/O and side effects; this reducer owns provider identity, legal phase changes,
/// reconciliation thresholds, and exactly-one terminalization. Keeping those rules here makes the
/// App Server adapter deterministic under dropped, duplicated, reordered, and stale-generation
/// events instead of spreading lifecycle policy across transport callbacks.
export class CodexLifecycleReducer {
  constructor({ mismatchLimit = 3, failureLimit = 2 } = {}) {
    this.mismatchLimit = boundedPositiveInteger(mismatchLimit, 3)
    this.failureLimit = boundedPositiveInteger(failureLimit, 2)
    this.phase = null
    this.resumePhase = 'providerActive'
    this.processGeneration = null
    this.threadId = null
    this.turnId = null
    this.reconciliationFailures = 0
    this.ownershipMismatches = 0
    this.terminalTransitions = 0
  }

  snapshot() {
    return {
      phase: this.phase,
      processGeneration: this.processGeneration,
      threadId: this.threadId,
      turnId: this.turnId,
      reconciliationFailures: this.reconciliationFailures,
      ownershipMismatches: this.ownershipMismatches,
      terminalTransitions: this.terminalTransitions,
    }
  }

  get isTerminal() {
    return CODEX_TERMINAL_PHASES.has(this.phase)
  }

  #bindIdentity({ processGeneration, threadId, turnId } = {}) {
    const bindings = []
    for (const [key, candidate] of [
      ['processGeneration', processGeneration],
      ['threadId', threadId],
      ['turnId', turnId],
    ]) {
      if (candidate === undefined || candidate === null || candidate === '') continue
      const valid = key === 'processGeneration'
        ? Number.isInteger(candidate) && candidate >= 0
        : typeof candidate === 'string'
      if (!valid) return { accepted: false, reason: `invalid_${key}` }
      if (this[key] !== null && this[key] !== candidate) {
        return { accepted: false, reason: `stale_${key}` }
      }
      bindings.push([key, candidate])
    }
    for (const [key, candidate] of bindings) this[key] = candidate
    return { accepted: true }
  }

  transition(nextPhase, identity = {}) {
    const previousState = this.phase
    if (!CODEX_LIFECYCLE_PHASE_SET.has(nextPhase)) {
      return {
        accepted: false, reason: 'unknown_phase', previousState,
        nextState: previousState,
      }
    }
    const identityResult = this.#bindIdentity(identity)
    if (!identityResult.accepted) {
      return {
        ...identityResult, previousState, nextState: previousState,
      }
    }
    if (this.isTerminal) {
      return nextPhase === previousState
        ? { accepted: true, idempotent: true, previousState, nextState: previousState }
        : {
            accepted: false, reason: 'already_terminal', previousState,
            nextState: previousState,
          }
    }
    const allowed = CODEX_LIFECYCLE_TRANSITIONS.get(previousState)
    if (!allowed?.has(nextPhase)) {
      return {
        accepted: false, reason: 'invalid_transition', previousState,
        nextState: previousState,
      }
    }
    if (nextPhase === 'reconciling' && CODEX_RESUMABLE_PHASES.has(previousState)) {
      this.resumePhase = previousState
    }
    this.phase = nextPhase
    if (CODEX_TERMINAL_PHASES.has(nextPhase)) this.terminalTransitions += 1
    return {
      accepted: true,
      idempotent: previousState === nextPhase,
      previousState,
      nextState: nextPhase,
    }
  }

  noteActivity() {
    this.reconciliationFailures = 0
    this.ownershipMismatches = 0
  }

  beginReconciliation(identity = {}) {
    return { action: 'probe', ...this.transition('reconciling', identity) }
  }

  reconcile(outcome) {
    if (!outcome || typeof outcome.kind !== 'string') {
      outcome = { kind: 'invalid', reason: 'missing_outcome' }
    }
    if (this.isTerminal) {
      return {
        action: 'ignoreTerminal', accepted: true, idempotent: true,
        previousState: this.phase, nextState: this.phase,
      }
    }

    switch (outcome.kind) {
      case 'terminal': {
        this.reconciliationFailures = 0
        this.ownershipMismatches = 0
        return {
          action: 'terminal',
          ...this.transition(codexTerminalPhase(outcome.turn?.status)),
        }
      }
      case 'active': {
        this.reconciliationFailures = 0
        this.ownershipMismatches = 0
        return {
          action: 'remainActive',
          ...this.transition(outcome.lifecycleState || 'providerActive'),
        }
      }
      case 'missingActive':
      case 'inconsistent': {
        this.reconciliationFailures = 0
        this.ownershipMismatches += 1
        if (this.ownershipMismatches >= this.mismatchLimit) {
          return {
            action: 'recoverableOrphan',
            ...this.transition('recoverableOrphan'),
          }
        }
        return {
          action: 'retryOwnership',
          ...this.transition(
            outcome.lifecycleState || this.resumePhase || 'providerActive',
          ),
        }
      }
      case 'orphaned': {
        this.reconciliationFailures = 0
        return {
          action: 'recoverableOrphan',
          ...this.transition('recoverableOrphan'),
        }
      }
      case 'systemError':
        return { action: 'systemError', ...this.transition('failed') }
      default: {
        this.reconciliationFailures += 1
        if (this.reconciliationFailures >= this.failureLimit) {
          return { action: 'restartInvalid', ...this.transition('failed') }
        }
        return {
          action: 'retryInvalid',
          ...this.transition(this.resumePhase || 'providerActive'),
        }
      }
    }
  }

  reconcileFailure() {
    if (this.isTerminal) {
      return {
        action: 'ignoreTerminal', accepted: true, idempotent: true,
        previousState: this.phase, nextState: this.phase,
      }
    }
    this.reconciliationFailures += 1
    if (this.reconciliationFailures >= this.failureLimit) {
      return { action: 'restartUnresponsive', ...this.transition('failed') }
    }
    return {
      action: 'retryFailure',
      ...this.transition(this.resumePhase || 'providerActive'),
    }
  }

  finish(status, { interrupted = false } = {}) {
    if (this.isTerminal) {
      return {
        accepted: true, idempotent: true, previousState: this.phase,
        nextState: this.phase,
      }
    }
    return this.transition(codexTerminalPhase(status, interrupted))
  }
}

export function codexConversationHash(value) {
  if (typeof value !== 'string' || !value) return null
  return createHash('sha256').update(value, 'utf8').digest('hex').slice(0, 16)
}

export class CodexLifecycleTrace {
  constructor({
    runtimeId,
    codexVersion = null,
    schemaHash = null,
    maxEntries = 256,
    log = () => {},
    now = () => new Date(),
    monotonicNow = () => performance.now(),
  } = {}) {
    this.runtimeId = runtimeId || null
    this.codexVersion = codexVersion
    this.schemaHash = schemaHash
    this.maxEntries = Math.max(1, Math.floor(maxEntries))
    this.log = log
    this.now = now
    this.monotonicNow = monotonicNow
    this.buffer = []
  }

  record(input = {}) {
    const details = {}
    for (const key of TRACE_DETAIL_KEYS) {
      const value = traceDetailValue(key, input[key])
      if (value !== undefined) details[key] = value
    }
    const record = {
      recordedAt: this.now().toISOString(),
      monotonicMs: Math.round(this.monotonicNow()),
      runtimeId: this.runtimeId,
      codexVersion: typeof input.codexVersion === 'string'
        ? input.codexVersion.slice(0, 64)
        : this.codexVersion,
      schemaHash: typeof input.schemaHash === 'string'
        ? input.schemaHash.slice(0, 128)
        : this.schemaHash,
      processGeneration: Number.isInteger(input.processGeneration)
        ? input.processGeneration
        : null,
      clientTurnId: boundedTraceString(input.clientTurnId, 128) || null,
      conversationHash: codexConversationHash(input.conversationId),
      provider: 'codex',
      auth: 'subscription',
      model: boundedTraceString(input.model, 128) || null,
      effort: boundedTraceString(input.effort, 64) || null,
      threadId: boundedTraceString(input.threadId, 128) || null,
      turnId: boundedTraceString(input.turnId, 128) || null,
      event: boundedTraceString(input.event, 128) || 'unknown',
      previousState: boundedTraceString(input.previousState, 64) || null,
      nextState: boundedTraceString(input.nextState, 64) || null,
      ...details,
    }
    this.buffer.push(record)
    if (this.buffer.length > this.maxEntries) {
      this.buffer.splice(0, this.buffer.length - this.maxEntries)
    }
    this.log(JSON.stringify(record))
    return record
  }

  entries() {
    return this.buffer.map((entry) => ({ ...entry }))
  }

  exportSnapshot() {
    const entries = this.entries()
    const latestRuntimeMetadata = [...entries].reverse().find((entry) =>
      entry.codexVersion || entry.schemaHash || Number.isInteger(entry.processGeneration))
    return {
      format: 'ai.mechanician.codex-lifecycle.v1',
      exportedAt: this.now().toISOString(),
      redaction: {
        prompts: 'excluded',
        output: 'excluded',
        toolPayloads: 'excluded',
        environment: 'excluded',
        credentials: 'excluded',
        conversationIdentifiers: 'sha256-prefix',
      },
      runtime: {
        runtimeId: this.runtimeId,
        codexVersion: latestRuntimeMetadata?.codexVersion || this.codexVersion || null,
        schemaHash: latestRuntimeMetadata?.schemaHash || this.schemaHash || null,
        processGeneration: latestRuntimeMetadata?.processGeneration ?? null,
      },
      entryCount: entries.length,
      maximumEntryCount: this.maxEntries,
      entries,
    }
  }
}
