// Experimental Conversation Record v0. This is an inspectable export binding, not the live
// Conversation authority and not a compatibility promise. The byte format is intentionally small:
// a fixed prelude, CRC-protected JSON frames, and a final commit over the exact preceding bytes.
import crypto from 'node:crypto'
import fs from 'node:fs'
import path from 'node:path'

import { canonicalFromSidecar } from './canonical-from-sidecar.mjs'

export const PRELUDE = Buffer.from([
  0x43, 0x4f, 0x4e, 0x56, 0x52, 0x45, 0x43, 0x00, // CONVREC\0
  0x00, 0x00, // little-endian version 0
  0x01, 0x00, // experimental/no-compatibility flag
  0x10, 0x00, 0x00, 0x00, // prelude size 16
])
export const MAX_FRAME_BYTES = 16 * 1024 * 1024
export const MAX_RECORD_BYTES = 512 * 1024 * 1024
export const PROFILE_LOCAL_FULL = 'ai.mechanician.local-full/0-experimental'
export const PROFILE_SHARE_SNAPSHOT = 'ai.mechanician.share-snapshot/0-experimental'
export const EXPERIMENTAL_CANONICAL_FORMAT =
  'ai.mechanician.conversation-record/0-experimental'

const CRC_TABLE = new Uint32Array(256).map((_, n) => {
  let value = n
  for (let bit = 0; bit < 8; bit += 1) {
    value = value & 1 ? 0xedb88320 ^ (value >>> 1) : value >>> 1
  }
  return value >>> 0
})

export function crc32(buffer) {
  let value = 0xffffffff
  for (let index = 0; index < buffer.length; index += 1) {
    value = CRC_TABLE[(value ^ buffer[index]) & 0xff] ^ (value >>> 8)
  }
  return (value ^ 0xffffffff) >>> 0
}

function sorted(value) {
  if (Array.isArray(value)) return value.map(sorted)
  if (value && typeof value === 'object') {
    return Object.fromEntries(Object.keys(value).sort().map((key) => [key, sorted(value[key])]))
  }
  return value
}

export function stableJSON(value) {
  return JSON.stringify(sorted(value))
}

function uuidV8URN() {
  const bytes = crypto.randomBytes(16)
  bytes[6] = (bytes[6] & 0x0f) | 0x80
  bytes[8] = (bytes[8] & 0x3f) | 0x80
  const hex = bytes.toString('hex')
  const uuid = `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`
  return `urn:uuid:${uuid}`
}

function encodeFrame(object) {
  const payload = Buffer.from(stableJSON(object), 'utf8')
  if (payload.length > MAX_FRAME_BYTES) {
    throw new Error(`experimental frame exceeds ${MAX_FRAME_BYTES} bytes`)
  }
  const header = Buffer.alloc(8)
  header.writeUInt32LE(payload.length, 0)
  header.writeUInt32LE(crc32(payload), 4)
  return Buffer.concat([header, payload])
}

function privateOmissions(sidecar) {
  const meaningful = (value) => {
    if (value == null || value === '' || value === false) return false
    if (Array.isArray(value)) return value.length > 0
    if (typeof value === 'object') return Object.keys(value).length > 0
    return true
  }
  const present = (keys) => keys.reduce(
    (count, key) => count + (meaningful(sidecar[key]) ? 1 : 0), 0)
  return [
    {
      code: 'private-local-machine-context',
      count: present(['cwd', 'projectID', 'favorite', 'sortIndex', 'unread', 'errored']),
      reason: 'machine paths, Workspace membership, and UI organization remain private local state',
    },
    {
      code: 'private-provider-resume-state',
      count: present([
        'sdkSessionId', 'sdkSessionRouteIdentity', 'sdkSessionExtensionRevision',
        'sdkSessionWorkspaceInstructionsRevision', 'claudeEffectiveModel',
      ]),
      reason: 'provider resume and route handles are operative private state',
    },
    {
      code: 'private-drafts-queues-and-waits',
      count: present([
        'queuedPrompts', 'pendingTurnPrompt', 'draft', 'armedTrigger', 'providerAccessRequest',
      ]),
      reason: 'unsent work, queues, grants, and armed waits never become portable content',
    },
  ]
}

function unsupportedOmissions(sidecar) {
  const reviewCount = (sidecar.messages ?? []).filter((row) => row.kind === 'review').length
  const unprojectedMessageDetails = (sidecar.messages ?? []).filter((row) =>
    row.usageLimit != null || row.providerFailure != null || row.toolImage != null
      || row.guidanceState != null
    ).length
  const unprojectedDelegateDetails = Object.values(sidecar.subagents ?? {}).filter((row) =>
    row.agentPath != null || row.taskId != null || row.tokens != null
      || row.toolEvents != null || row.summary != null).length
  return [
    {
      code: 'artifact-media-bytes-not-yet-projected',
      count: Array.isArray(sidecar.artifacts) ? sidecar.artifacts.length : 0,
      reason: 'artifact/blob ownership is not frozen in experimental v0',
    },
    {
      code: 'model-attribution-not-yet-projected',
      count: sidecar.modelSelection == null ? 0 : 1,
      reason: 'requested/observed model attribution still needs a canonical parity proof',
    },
    {
      code: 'legacy-context-summary-not-yet-projected',
      count: ['contextTokens', 'contextWindow', 'contextModel']
        .filter((key) => sidecar[key] != null).length,
      reason: 'legacy latest-state context fields are not silently promoted into event history',
    },
    {
      code: 'legacy-fork-provenance-private',
      count: sidecar.forkProvenance == null ? 0 : 1,
      reason: 'legacy local Conversation identities are not inferred to be portable lineage',
    },
    {
      code: 'provider-review-detail-not-yet-projected',
      count: reviewCount,
      reason: 'provider review lifecycle does not yet have a canonical v0 mapping',
    },
    {
      code: 'message-lifecycle-detail-not-yet-projected',
      count: unprojectedMessageDetails,
      reason: 'failure, media, guidance, and compaction refinements await canonical parity',
    },
    {
      code: 'delegate-detail-not-yet-projected',
      count: unprojectedDelegateDetails,
      reason: 'delegate path, usage, and bounded summary projections await canonical parity',
    },
    {
      code: 'title-provenance-and-recency-not-yet-projected',
      count: (sidecar.titleSource == null ? 0 : 1) + (sidecar.updatedAt == null ? 0 : 1),
      reason: 'the display-name snapshot is retained, but title provenance and recency are not claims',
    },
  ]
}

function remintEventIdentities(canonical) {
  const eventIDs = new Map()
  const toolIDs = new Map()
  const remint = (map, value, prefix) => {
    if (typeof value !== 'string' || value.length === 0) return value
    if (!map.has(value)) map.set(value, `${prefix}-${map.size + 1}`)
    return map.get(value)
  }
  for (const event of canonical.events) {
    if (event.eventId != null) remint(eventIDs, event.eventId, 'event')
  }
  const events = canonical.events.map((event) => {
    const copy = structuredClone(event)
    for (const key of ['eventId', 'targetEventId', 'replacementEventId', 'producingEventId']) {
      if (copy[key] != null) copy[key] = remint(eventIDs, copy[key], 'event')
    }
    if (copy.toolUseId != null) copy.toolUseId = remint(toolIDs, copy.toolUseId, 'tool')
    return copy
  })
  return { ...canonical, events }
}

function collectPrivateOperativeTokens(sidecar) {
  const tokens = new Set()
  const add = (value) => {
    // Short values such as `root`, model names, or ordinary prose are too ambiguous to scrub
    // globally. Operative handles and persisted ids in this store are UUID/opaque-token shaped.
    if (typeof value === 'string' && value.length >= 12 && value.length <= 2_048) {
      tokens.add(value)
    }
  }
  const addPath = (value) => {
    if (typeof value === 'string' && value.length <= 2_048
        && (value.startsWith('/') || /^[A-Za-z]:\\/.test(value))) {
      tokens.add(value)
    }
  }
  const addStrings = (value) => {
    if (typeof value === 'string') add(value)
    else if (Array.isArray(value)) value.forEach(addStrings)
    else if (value && typeof value === 'object') Object.values(value).forEach(addStrings)
  }
  const addFields = (object, fields) => {
    if (!object || typeof object !== 'object') return
    for (const field of fields) addStrings(object[field])
  }

  addFields(sidecar, [
    'id', 'projectID', 'sdkSessionId', 'sdkSessionRouteIdentity',
    'sdkSessionExtensionRevision', 'sdkSessionWorkspaceInstructionsRevision',
  ])
  addPath(sidecar.cwd)
  addFields(sidecar.providerAccessRequest, ['id'])
  for (const message of sidecar.messages ?? []) {
    addFields(message, [
      'id', 'permissionId', 'questionId', 'providerFrameUUID', 'supersededByFrameUUID',
      'compactionTurnID', 'toolTurnID', 'toolOwnerAgentID', 'toolUseId',
      'supersessionEventID', 'supersededByEntryID',
    ])
  }
  for (const [storageKey, subagent] of Object.entries(sidecar.subagents ?? {})) {
    add(storageKey)
    addFields(subagent, ['key', 'taskId', 'parentToolUseId', 'agentPath'])
  }
  for (const [storageKey, workflow] of Object.entries(sidecar.workflowRuns ?? {})) {
    add(storageKey)
    addFields(workflow, ['runKey', 'sessionId', 'runTaskId', 'toolUseId'])
    for (const [agentKey, agent] of Object.entries(workflow.agents ?? {})) {
      add(agentKey)
      addFields(agent, ['agentId', 'taskId', 'toolUseId', 'sessionId'])
    }
  }
  for (const activity of sidecar.agentActivity ?? []) {
    addFields(activity, ['id', 'turnID', 'agentID'])
  }
  return [...tokens].sort((left, right) => right.length - left.length)
}

function scrubPrivateOperativeEchoes(canonical, sidecar) {
  const tokens = collectPrivateOperativeTokens(sidecar)
  if (tokens.length === 0) return { canonical, count: 0 }
  const escaped = tokens.map((token) => token.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'))
  const pattern = new RegExp(escaped.join('|'), 'g')
  let count = 0
  const scrub = (value) => {
    if (typeof value === 'string') {
      return value.replace(pattern, () => {
        count += 1
        return '[private operative value omitted]'
      })
    }
    if (Array.isArray(value)) return value.map(scrub)
    if (value && typeof value === 'object') {
      const output = {}
      for (const [key, child] of Object.entries(value)) {
        const scrubbedKey = scrub(key)
        let uniqueKey = scrubbedKey
        let collision = 2
        while (Object.hasOwn(output, uniqueKey)) {
          uniqueKey = `${scrubbedKey} #${collision}`
          collision += 1
        }
        output[uniqueKey] = scrub(child)
      }
      return output
    }
    return value
  }
  return { canonical: scrub(canonical), count }
}

const SHARE_EVENT_KINDS = new Set([
  'user_message', 'assistant_message', 'system', 'compaction', 'history_reduction',
  'context_usage', 'usage', 'supersession', 'agent_identity', 'agent_lifecycle',
  'agent_spawn', 'agent_call_result',
])
// The default sharing transform is fail-closed. New canonical fields do not become shareable merely
// because a producer learned to emit them; each entity and event kind has its own reviewed shape.
// In particular, `text` is legal only on the three explicit dialog kinds. A global field allowlist
// would let a future lifecycle/tool field named `text` escape review.
const SHARE_GRAPH_KEYS = new Set([
  'format', 'agents', 'workflows', 'workflowPhases', 'chronology', 'events',
])
const SHARE_AGENT_KEYS = new Set([
  'id', 'parentId', 'type', 'workflowId', 'phaseId', 'sourceOrdinal', 'attempt',
  'observedModel', 'identityProvenance', 'parentageProvenance', 'metadataProvenance',
])
const SHARE_WORKFLOW_KEYS = new Set([
  'id', 'ownerAgentId', 'type', 'providerConfirmed',
  'identityProvenance', 'parentageProvenance', 'metadataProvenance',
])
const SHARE_WORKFLOW_PHASE_KEYS = new Set([
  'id', 'workflowId', 'sourceOrdinal', 'identityProvenance',
])
const SHARE_CHRONOLOGY_KEYS = new Set([
  'status', 'basis', 'diagnostic', 'eventCount', 'capturedOrdinalEventCount',
  'missingCaptureOrdinalEventCount', 'invalidCaptureOrdinalEventCount',
  'stableEventIdEventCount', 'missingStableEventIdEventCount',
  'duplicateStableEventIdEventCount', 'legacySummaryEventCount',
  'degradedWorkflowSummaryEventCount', 'maximumCaptureOrdinal', 'captureBatchCount',
  'tieSemantics', 'serializationOrder',
])
const SHARE_USAGE_KEYS = new Set([
  'inputTokens', 'cachedInputTokens', 'outputTokens', 'reasoningOutputTokens',
  'totalTokens', 'durationMs', 'toolUses',
])
const EVENT_COMMON_KEYS = [
  'kind', 'eventId', 'agentId', 'observedAt', 'captureOrdinal', 'timeProvenance',
  'chronologyProvenance',
]
const eventKeys = (...keys) => new Set([...EVENT_COMMON_KEYS, ...keys])
const SHARE_EVENT_KEYS = new Map([
  ['user_message', eventKeys(
    'text', 'recipientAgentId', 'turnId', 'providerAccess', 'observedModel',
    'activityProvenance', 'userEventKind', 'disposition', 'deliveryProvenance')],
  ['assistant_message', eventKeys('text')],
  ['system', eventKeys('text', 'sourceKind')],
  ['compaction', eventKeys(
    'turnId', 'trigger', 'preTokens', 'postTokens', 'isError', 'outcome',
    'providerAccess', 'observedModel', 'activityProvenance', 'compactionProvenance')],
  ['history_reduction', eventKeys(
    'turnId', 'providerAccess', 'observedModel', 'agentLabel', 'activityProvenance',
    'contextProvenance', 'omittedMessages', 'shortenedMessages')],
  ['context_usage', eventKeys(
    'turnId', 'providerAccess', 'observedModel', 'agentLabel', 'activityProvenance',
    'contextProvenance', 'contextTokens', 'contextWindow', 'model')],
  ['usage', eventKeys(
    'turnId', 'providerAccess', 'observedModel', 'agentLabel', 'activityProvenance',
    'usageProvenance', 'inputTokens', 'cachedInputTokens', 'outputTokens',
    'reasoningOutputTokens', 'totalTokens', 'workflowId', 'phaseId', 'durationMs',
    'toolUses')],
  ['supersession', eventKeys(
    'targetEventId', 'replacementEventId', 'historicalOnly', 'reason')],
  ['agent_identity', eventKeys(
    'turnId', 'providerAccess', 'observedModel', 'agentLabel', 'activityProvenance',
    'identityProvenance')],
  ['agent_lifecycle', eventKeys(
    'turnId', 'workflowId', 'phaseId', 'providerAccess', 'observedModel',
    'activityProvenance', 'stateProvenance', 'summaryProvenance', 'phase', 'state',
    'outcome', 'isError', 'attempt', 'durationMs', 'usage')],
  ['agent_spawn', eventKeys(
    'spawnedAgentId', 'agentType', 'phase', 'spawnProvenance')],
  ['agent_call_result', eventKeys(
    'completedAgentId', 'status', 'outcome', 'isError', 'stateProvenance')],
])

function redactPaths(text, counter) {
  if (typeof text !== 'string') return text
  // Exclude URLs, then redact common POSIX and Windows absolute paths embedded in retained dialog.
  const pattern = /(?<![:\w])\/(?:Users|Volumes|private|var|tmp|opt|usr|etc|Applications|Library|System|home)(?:\/[^\s"'`<>()\[\]{};,]+)+|\b[A-Za-z]:\\(?:[^\s"'`<>()\[\]{};,]+\\)*[^\s"'`<>()\[\]{};,]*/g
  return text.replace(pattern, () => {
    counter.count += 1
    return '[absolute path omitted]'
  })
}

function projectReviewedObject(value, allowedKeys, counter, nestedAllowlist = {}) {
  const output = {}
  for (const [key, child] of Object.entries(value ?? {})) {
    if (!allowedKeys.has(key)) {
      counter.contentFields += 1
      continue
    }
    if (nestedAllowlist[key]) {
      if (child == null) output[key] = child
      else if (child && typeof child === 'object' && !Array.isArray(child)) {
        output[key] = projectReviewedObject(child, nestedAllowlist[key], counter)
      } else counter.contentFields += 1
      continue
    }
    if (child == null || ['string', 'number', 'boolean'].includes(typeof child)) {
      output[key] = redactPaths(child, counter)
    } else {
      // No reviewed scalar field silently becomes a nested disclosure surface after schema drift.
      counter.contentFields += 1
    }
  }
  return output
}

export function applyExperimentalDisclosureProfile(canonical, profile) {
  if (profile === PROFILE_LOCAL_FULL) {
    return { canonical, omissions: [] }
  }
  if (profile !== PROFILE_SHARE_SNAPSHOT) throw new Error(`unsupported profile: ${profile}`)

  const counter = { count: 0, contentFields: 0 }
  const droppedKinds = new Map()
  const events = []
  for (const event of canonical.events) {
    if (!SHARE_EVENT_KINDS.has(event.kind)) {
      droppedKinds.set(event.kind, (droppedKinds.get(event.kind) ?? 0) + 1)
      continue
    }
    events.push(projectReviewedObject(
      event, SHARE_EVENT_KEYS.get(event.kind), counter, { usage: SHARE_USAGE_KEYS }))
  }
  const graph = {}
  for (const [key, child] of Object.entries(canonical)) {
    if (!SHARE_GRAPH_KEYS.has(key)) {
      counter.contentFields += 1
      continue
    }
    switch (key) {
      case 'agents':
        graph.agents = Array.isArray(child)
          ? child.map((item) => projectReviewedObject(item, SHARE_AGENT_KEYS, counter))
          : []
        break
      case 'workflows':
        graph.workflows = Array.isArray(child)
          ? child.map((item) => projectReviewedObject(item, SHARE_WORKFLOW_KEYS, counter))
          : []
        break
      case 'workflowPhases':
        graph.workflowPhases = Array.isArray(child)
          ? child.map((item) => projectReviewedObject(item, SHARE_WORKFLOW_PHASE_KEYS, counter))
          : []
        break
      case 'chronology':
        graph.chronology = projectReviewedObject(child, SHARE_CHRONOLOGY_KEYS, counter)
        break
      case 'events':
        break
      default:
        graph[key] = redactPaths(child, counter)
        break
    }
  }
  graph.events = events
  // Disclosure creates a different retained event set. Its chronology must describe those exact
  // frames rather than the pre-disclosure graph. Ordering of a retained subset remains truthful;
  // every derived count is recomputed from the bytes that will actually be written.
  const ordinals = events
    .map((event) => event.captureOrdinal)
    .filter((value) => Number.isSafeInteger(value) && value > 0)
  const stableIDs = events
    .map((event) => event.eventId)
    .filter((value) => typeof value === 'string' && value.length > 0)
  graph.chronology = {
    ...(graph.chronology ?? {}),
    eventCount: events.length,
    capturedOrdinalEventCount: ordinals.length,
    missingCaptureOrdinalEventCount: events.length - ordinals.length,
    invalidCaptureOrdinalEventCount: 0,
    stableEventIdEventCount: stableIDs.length,
    missingStableEventIdEventCount: events.length - stableIDs.length,
    duplicateStableEventIdEventCount: stableIDs.length - new Set(stableIDs).size,
    maximumCaptureOrdinal: ordinals.length > 0 ? Math.max(...ordinals) : null,
    captureBatchCount: new Set(ordinals).size,
  }
  const omissions = [
    {
      code: 'share-sensitive-event-content',
      count: [...droppedKinds.values()].reduce((total, count) => total + count, 0),
      details: Object.fromEntries([...droppedKinds].sort()),
      reason: 'tool and historical interaction content is excluded from the conservative profile',
    },
    {
      code: 'share-non-dialog-content-fields',
      count: counter.contentFields,
      reason: 'every canonical field not on the reviewed structural/dialog allowlist is excluded',
    },
    {
      code: 'share-absolute-path-text',
      count: counter.count,
      reason: 'absolute paths embedded in retained dialog are replaced',
    },
  ]
  return { canonical: graph, omissions }
}

export function encodeExperimentalConversationRecord({
  sidecar,
  profile,
  producer = {},
  exportedAt = new Date().toISOString(),
  lineageID = uuidV8URN(),
  versionID = uuidV8URN(),
}) {
  // The evidence adapter preserves source row ids for parity diagnostics. An exported bundle has
  // its own identity domain, so remint those ids and every cross-reference before disclosure.
  const reminted = remintEventIdentities({
    ...canonicalFromSidecar(sidecar),
    format: EXPERIMENTAL_CANONICAL_FORMAT,
  })
  // A private handle can be echoed inside otherwise-retained dialog or tool text. Remove exact
  // classified source values after structural ids are reminted, so correlations remain intact while
  // an operative resume/path/id token cannot hitchhike in either disclosure profile.
  const scrubbed = scrubPrivateOperativeEchoes({
    ...reminted,
    record: {
      conversationLineageID: lineageID,
      recordVersionID: versionID,
      identityProvenance: 'fresh-random-v8-experimental-export',
      displayName: profile === PROFILE_SHARE_SNAPSHOT
        ? 'Shared Conversation'
        : (typeof sidecar.title === 'string' ? sidecar.title : 'Conversation'),
    },
  }, sidecar)
  const { record, ...scrubbedCanonical } = scrubbed.canonical
  const profiled = applyExperimentalDisclosureProfile(scrubbedCanonical, profile)
  const { events, ...graphWithoutEvents } = profiled.canonical
  const graph = {
    ...graphWithoutEvents,
    record,
  }
  const omissions = [
    ...privateOmissions(sidecar),
    {
      code: 'private-operative-value-echoes',
      count: scrubbed.count,
      reason: 'exact private handles, local paths, and source ids echoed in retained text are replaced',
    },
    ...unsupportedOmissions(sidecar),
    ...profiled.omissions,
  ]
  const manifest = {
    frameType: 'manifest',
    documentType: 'ai.mechanician.conversation-record',
    formatVersion: 0,
    compatibility: 'experimental-no-compatibility',
    binding: 'framed-json-crc32-commit/0-experimental',
    profile,
    exportedAt,
    producer: {
      name: 'Mechanician',
      version: producer.version ?? null,
      build: producer.build ?? null,
      sourceRevision: producer.sourceRevision ?? null,
    },
    identity: {
      conversationLineageID: lineageID,
      recordVersionID: versionID,
      sourcePortableLineage: 'unavailable',
    },
    disclosure: {
      omissions,
      warning: profile === PROFILE_SHARE_SNAPSHOT
        ? 'Retains user and assistant dialog; review the exported file before sharing.'
        : 'Retains mapped dialog, tool, interaction, and agent content; keep private unless reviewed.',
    },
    counts: {
      agents: Array.isArray(graph.agents) ? graph.agents.length : 0,
      workflows: Array.isArray(graph.workflows) ? graph.workflows.length : 0,
      events: events.length,
    },
  }

  const nonCommitFrames = [
    encodeFrame(manifest),
    encodeFrame({ frameType: 'graph', graph }),
    ...events.map((event) => encodeFrame({ frameType: 'event', event })),
  ]
  const committedPrefix = Buffer.concat([PRELUDE, ...nonCommitFrames])
  const contentDigest = crypto.createHash('sha256').update(committedPrefix).digest('hex')
  const commit = {
    frameType: 'commit',
    committedFrameCount: nonCommitFrames.length,
    committedByteLength: committedPrefix.length,
    contentDigestSHA256: contentDigest,
  }
  const bytes = Buffer.concat([committedPrefix, encodeFrame(commit)])
  if (bytes.length > MAX_RECORD_BYTES) {
    throw new Error(`experimental record exceeds ${MAX_RECORD_BYTES} bytes`)
  }
  return {
    bytes,
    report: {
      formatVersion: 0,
      profile,
      lineageID,
      versionID,
      contentDigestSHA256: contentDigest,
      byteDigestSHA256: crypto.createHash('sha256').update(bytes).digest('hex'),
      bytes: bytes.length,
      agents: manifest.counts.agents,
      events: events.length,
      chronology: graph.chronology?.status ?? 'unknown',
      omissions,
      trailingUncommittedBytes: 0,
    },
  }
}

export function writeExperimentalConversationRecord(options, destination) {
  const encoded = encodeExperimentalConversationRecord(options)
  const directory = path.dirname(destination)
  let descriptor
  try {
    // The native app supplies a unique, non-existing sibling staging path and owns its cleanup.
    // Writing that path directly means SIGKILL cannot strand an untracked second-level temp file;
    // Swift validates it independently before publishing it at the user's destination.
    descriptor = fs.openSync(destination, 'wx', 0o600)
    fs.writeFileSync(descriptor, encoded.bytes)
    fs.fsyncSync(descriptor)
    fs.closeSync(descriptor)
    descriptor = undefined
    try {
      const directoryDescriptor = fs.openSync(directory, 'r')
      try { fs.fsyncSync(directoryDescriptor) } finally { fs.closeSync(directoryDescriptor) }
    } catch {
      // Some network providers refuse directory fsync; the file itself is still fully committed.
    }
    return encoded.report
  } catch (error) {
    if (descriptor !== undefined) fs.closeSync(descriptor)
    try { fs.unlinkSync(destination) } catch {}
    throw error
  }
}
