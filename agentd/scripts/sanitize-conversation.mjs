#!/usr/bin/env node
// Stage A sanitizing exporter: turn a real conversation sidecar into a corpus derivative that is
// safe to review and (after review) commit as a fixture.
//
// SECURITY POSTURE — ALLOWLIST, FAIL CLOSED. Every key must be explicitly classified below.
// A key this table does not know is DROPPED and reported, never copied: schema drift can only
// ever remove data from the output, not leak it. The classifications:
//
//   keep         structural values a fixture needs verbatim (kinds, states, counts, booleans,
//                enum strings, tool names)
//   id           opaque identifier — re-minted to a deterministic pseudonym so real ids never
//                appear while cross-references inside the file stay intact
//   time         timestamp — shifted by one per-export seeded offset so every delta between
//                events is preserved but absolute times are meaningless
//   text         free prose — every word replaced by a same-length seeded token, whitespace and
//                newline structure preserved, so byte sizes and shapes survive for measurement
//                while no dogfood content does
//   path         filesystem path — replaced with /sanitized/<same-depth> placeholders
//   drop         never emitted (operative/private state has no business in a fixture at all)
//
// Output goes to stdout (or --out). A provenance report goes to stderr as JSON: source digest,
// output digest, per-class counts, and EVERY dropped-unknown key path. Derivatives still require
// human review before entering Git (corpus-manifest.json: dogfoodDataPermitted stays false).
//
// Usage: node sanitize-conversation.mjs --seed <string> <sidecar.json> [--out <file>]
import fs from 'node:fs'
import crypto from 'node:crypto'

const args = process.argv.slice(2)
let seed = null
let outPath = null
let inputPath = null
for (let i = 0; i < args.length; i += 1) {
  if (args[i] === '--seed') { seed = args[i + 1]; i += 1 }
  else if (args[i] === '--out') { outPath = args[i + 1]; i += 1 }
  else inputPath = args[i]
}
if (!seed || !inputPath) {
  console.error('usage: sanitize-conversation.mjs --seed <string> <sidecar.json> [--out <file>]')
  process.exit(64)
}

// ---------------------------------------------------------------------------------------------
// Policy. Paths use `[]` for any array index and match from each object's own root, so nested
// records (messages, artifacts, subagents…) declare their fields once.

const CONVERSATION_POLICY = {
  id: 'id',
  title: 'text',
  titleSource: 'keep',
  cwd: 'path',
  updatedAt: 'time',
  messages: { kind: 'array', of: 'ENTRY' },
  artifacts: { kind: 'array', of: 'ARTIFACT' },
  workflowRuns: { kind: 'map', of: 'WORKFLOW_RUN' },
  subagents: { kind: 'map', of: 'SUBAGENT' },
  agentActivity: { kind: 'array', of: 'ACTIVITY' },
  captureOrdinalHighWatermark: 'keep',
  contextTokens: 'keep',
  contextWindow: 'keep',
  contextModel: 'keep',
  modelSelection: { kind: 'object', of: 'MODEL_SELECTION' },
  forkProvenance: { kind: 'object', of: 'FORK_PROVENANCE' },
  // Operative/private state: a fixture must never carry it (accepted decision 2).
  sdkSessionId: 'drop',
  sdkSessionRouteIdentity: 'drop',
  sdkSessionExtensionRevision: 'drop',
  sdkSessionWorkspaceInstructionsRevision: 'drop',
  queuedPrompts: 'drop',
  pendingTurnPrompt: 'drop',
  draft: 'drop',
  favorite: 'drop',
  sortIndex: 'drop',
  armedTrigger: 'drop',
  unread: 'drop',
  errored: 'drop',
  projectID: 'drop',
  providerAccessRequest: 'drop',
  claudePreferences: 'drop',
  claudeEffectiveModel: 'drop',
}

const SCHEMAS = {
  ENTRY: {
    id: 'id',
    kind: 'keep',
    text: 'text',
    observedAt: 'time',
    captureOrdinal: 'keep',
    toolName: 'keep',
    toolResult: 'text',
    toolIsError: 'keep',
    toolUseId: 'id',
    toolState: 'keep',
    toolResultCaptureOrdinal: 'keep',
    toolTerminalCaptureOrdinal: 'keep',
    providerFrameUUID: 'id',
    supersededByFrameUUID: 'id',
    supersessionEventID: 'id',
    supersededByEntryID: 'id',
    supersessionCaptureOrdinal: 'keep',
    guidanceState: 'keep',
    guidanceFailureReason: 'text',
    permissionId: 'id',
    permName: 'keep',
    permDecided: 'keep',
    permAllowed: 'keep',
    permAlways: 'keep',
    interactionResponseStatus: 'keep',
    interactionResponseObservedAt: 'time',
    interactionAcknowledgedAt: 'time',
    interactionResponseCaptureOrdinal: 'keep',
    interactionAcknowledgedCaptureOrdinal: 'keep',
    interactionClosure: { kind: 'object', of: 'INTERACTION_CLOSURE' },
    questionId: 'id',
    questionDecided: 'keep',
    questionFreeTextResponse: 'text',
    compactionTrigger: 'keep',
    compactionPreTokens: 'keep',
    compactionPostTokens: 'keep',
    compactionError: 'text',
    compactionTurnID: 'id',
    usageLimit: 'drop',        // provider account details
    providerFailure: 'drop',   // provider payloads can quote prompts
    providerFailurePromptID: 'id',
    refusal: 'drop',
    review: 'drop',            // review records carry raw diff prose; out of fixture scope
    imagePaths: 'drop',
    toolImage: 'drop',
    questions: 'drop',         // question/answer prose; structure covered by decided flags
    questionAnswers: 'drop',
  },
  INTERACTION_CLOSURE: {
    outcome: 'keep',
    // Swift deliberately accepts future reason vocabulary. Treat it as prose here so an
    // unexpectedly descriptive provider reason can never bypass the exporter text scrubber.
    reason: 'text',
    observedAt: 'time',
    captureOrdinal: 'keep',
  },
  ARTIFACT: {
    uuid: 'id',
    name: 'text',
    title: 'text',
    type: 'keep',
    source: 'text',            // artifact CONTENT — shape kept, bytes replaced
    revisions: 'keep',
    createdAt: 'time',
    updatedAt: 'time',
    origin: 'keep',
    conversationID: 'id',
    conversationTitle: 'text',
    workspaceID: 'id',
    cwd: 'path',
    taskId: 'id',
  },
  WORKFLOW_RUN: {
    runKey: 'id',
    sessionId: 'drop',          // provider session handle — operative, never a fixture value
    toolUseId: 'id',
    runTaskId: 'id',
    workflowName: 'text',
    description: 'text',
    summary: 'text',
    status: 'keep',
    usage: 'drop',              // provider usage payload; token counts live on agents
    outputFile: 'path',
    error: 'text',
    startedAt: 'time',
    endedAt: 'time',
    label: 'text',
    agents: { kind: 'map', of: 'WORKFLOW_AGENT' },
  },
  WORKFLOW_AGENT: {
    index: 'keep',
    label: 'text',
    phaseIndex: 'keep',
    phaseTitle: 'text',
    state: 'keep',
    agentId: 'id',
    model: 'keep',
    attempt: 'keep',
    lastToolName: 'keep',
    lastToolSummary: 'text',
    promptPreview: 'text',
    tokens: 'keep',
    startedAt: 'time',
    endedAt: 'time',
    summary: 'text',
  },
  SUBAGENT: {
    key: 'id',
    taskId: 'id',
    agentPath: 'keep',          // structural tree position ("0:1"), not prose
    parentToolUseId: 'id',      // the delegation parentage edge — the graph must survive
    subagentType: 'keep',
    model: 'keep',
    task: 'text',
    summary: 'text',
    resultPreview: 'text',
    error: 'text',
    lastToolName: 'keep',
    status: 'keep',
    tokens: 'keep',
    toolUses: 'keep',
    toolUsesObserved: 'keep',
    durationMs: 'keep',
    startedAt: 'time',
    endedAt: 'time',
    startedCaptureOrdinal: 'keep',
    endedCaptureOrdinal: 'keep',
    toolEvents: { kind: 'array', of: 'TOOL_EVENT' },
  },
  TOOL_EVENT: {
    name: 'keep',
    target: 'text',
    state: 'keep',
    at: 'time',
  },
  // Field set verified against the real corpus 2026-08-02 (24-key union over the 20 largest
  // sidecars); the encoding is flat with an `agentID` of "root" or "subagent:<toolUseId>".
  ACTIVITY: {
    id: 'id',
    turnID: 'id',
    kind: 'keep',
    phase: 'keep',
    detail: 'text',
    toolTarget: 'text',
    at: 'time',
    agentID: 'agentid',
    agentLabel: 'keep',
    modelID: 'keep',
    providerAccess: 'keep',
    inputTokens: 'keep',
    outputTokens: 'keep',
    cachedInputTokens: 'keep',
    reasoningOutputTokens: 'keep',
    contextTokens: 'keep',
    contextWindow: 'keep',
    contextEventKind: 'keep',
    compactionTrigger: 'keep',
    historyReductionReason: 'keep',
    historyOmittedMessages: 'keep',
    historyShortenedMessages: 'keep',
    userEventKind: 'keep',
    interjectionDisposition: 'keep',
    captureOrdinal: 'keep',
  },
  MODEL_SELECTION: {
    access: 'keep',
    modelID: 'keep',
    effort: 'keep',
  },
  FORK_PROVENANCE: {
    kind: 'keep',
    sourceConversationID: 'id',
    sourceTitleSnapshot: 'text',
    forkPointEntryID: 'id',
    createdAt: 'time',
  },
}

// ---------------------------------------------------------------------------------------------
// Deterministic machinery, all keyed off HMAC(seed, …) so one seed reproduces one byte-exact
// derivative and different seeds share nothing.

const hmac = (label) => crypto.createHmac('sha256', seed).update(label).digest()

const idMap = new Map()
const pseudonymize = (value) => {
  const key = String(value)
  if (!idMap.has(key)) {
    const digest = hmac(`id:${key}`)
    const hex = digest.subarray(0, 16).toString('hex').toUpperCase()
    // RFC-4122-shaped so Swift's UUID(uuidString:) accepts it; version nibble pinned to 4.
    idMap.set(
      key,
      `${hex.slice(0, 8)}-${hex.slice(8, 12)}-4${hex.slice(13, 16)}-A${hex.slice(17, 20)}-${hex.slice(20, 32)}`)
  }
  return idMap.get(key)
}

// One offset for the whole export: deltas between every pair of timestamps survive exactly.
const offsetDays = (hmac('time-offset').readUInt32BE(0) % 3650) + 365
const shiftTime = (value) => {
  const parsed = Date.parse(value)
  if (Number.isNaN(parsed)) return '1990-01-01T00:00:00.000Z'
  return new Date(parsed - offsetDays * 86400000).toISOString()
}

let wordCounter = 0
const ALPHABET = 'abcdefghijklmnopqrstuvwxyz'
const scrambleWord = (word) => {
  const digest = hmac(`word:${wordCounter += 1}`)
  let out = ''
  for (let i = 0; i < word.length; i += 1) out += ALPHABET[digest[i % 32] % 26]
  return out
}
const scrambleText = (value) =>
  String(value).replace(/[^\s]+/gu, (word) => scrambleWord(word))

const sanitizePath = (value) => {
  const segments = String(value).split('/').filter(Boolean)
  return `/sanitized${segments.map((_, i) => `/dir${i}`).join('')}` || '/sanitized'
}

// ---------------------------------------------------------------------------------------------

const report = {
  redacted: 0, kept: 0, ids: 0, times: 0, paths: 0, dropped: 0,
  droppedUnknownKeys: new Set(),
}

const sanitizeValue = (value, rule, path) => {
  if (value === null || value === undefined) return value
  if (typeof rule === 'object') {
    if (rule.kind === 'array') {
      return Array.isArray(value)
        ? value.map((item, i) => sanitizeObject(item, SCHEMAS[rule.of], `${path}[${i}]`))
        : undefined
    }
    if (rule.kind === 'map') {
      const out = {}
      for (const [key, item] of Object.entries(value)) {
        out[pseudonymize(key)] = sanitizeObject(item, SCHEMAS[rule.of], `${path}.${key}`)
      }
      return out
    }
    if (rule.kind === 'object') {
      return sanitizeObject(value, SCHEMAS[rule.of], path)
    }
  }
  switch (rule) {
    case 'keep': report.kept += 1; return value
    case 'id': report.ids += 1; return pseudonymize(value)
    case 'agentid': {
      // "root" is structural; "subagent:<toolUseId>" embeds a real id — pseudonymize it through
      // the SAME map as every other id so activity rows still correlate with the subagent table.
      report.ids += 1
      const text = String(value)
      if (text === 'root') return text
      const separator = text.indexOf(':')
      if (separator < 0) return pseudonymize(text)
      return `${text.slice(0, separator)}:${pseudonymize(text.slice(separator + 1))}`
    }
    case 'time': report.times += 1; return shiftTime(value)
    case 'text': report.redacted += 1; return scrambleText(value)
    case 'path': report.paths += 1; return sanitizePath(value)
    default: report.dropped += 1; return undefined
  }
}

const sanitizeObject = (object, policy, path) => {
  if (object === null || typeof object !== 'object' || Array.isArray(object)) {
    // A structure the policy did not anticipate: fail closed.
    report.dropped += 1
    report.droppedUnknownKeys.add(`${path} (unexpected shape)`)
    return undefined
  }
  const out = {}
  for (const [key, value] of Object.entries(object)) {
    const rule = policy[key]
    if (rule === undefined) {
      report.dropped += 1
      report.droppedUnknownKeys.add(`${path}.${key}`)
      continue
    }
    const sanitized = sanitizeValue(value, rule, `${path}.${key}`)
    if (sanitized !== undefined) out[key] = sanitized
  }
  return out
}

const inputBytes = fs.readFileSync(inputPath)
const conversation = JSON.parse(inputBytes)
const sanitized = sanitizeObject(conversation, CONVERSATION_POLICY, '$')
const outputBytes = Buffer.from(`${JSON.stringify(sanitized, null, 1)}\n`)

if (outPath) fs.writeFileSync(outPath, outputBytes)
else process.stdout.write(outputBytes)

const provenance = {
  sourceDigest: `sha256:${crypto.createHash('sha256').update(inputBytes).digest('hex')}`,
  outputDigest: `sha256:${crypto.createHash('sha256').update(outputBytes).digest('hex')}`,
  sourceBytes: inputBytes.length,
  outputBytes: outputBytes.length,
  counts: {
    kept: report.kept, redacted: report.redacted, ids: report.ids,
    times: report.times, paths: report.paths, dropped: report.dropped,
  },
  droppedUnknownKeys: [...report.droppedUnknownKeys].sort(),
}
process.stderr.write(`${JSON.stringify(provenance, null, 1)}\n`)
