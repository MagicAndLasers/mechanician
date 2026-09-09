// Field-level evidence rules for the R2 spike. This is deliberately not a public schema: it makes
// the prototype fail closed when a reviewed source grows a field that the adapter has not
// classified, and it prevents a structural "skeleton" comparison from hiding payload loss.

import crypto from 'node:crypto'

function assertJSONValue(value, path = '$', ancestors = new WeakSet()) {
  if (value === null || typeof value === 'string' || typeof value === 'boolean') return
  if (typeof value === 'number') {
    if (!Number.isFinite(value)) throw new TypeError(`${path}: non-finite number is not JSON`)
    return
  }
  if (typeof value !== 'object') throw new TypeError(`${path}: ${typeof value} is not JSON`)
  if (ancestors.has(value)) throw new TypeError(`${path}: cyclic value is not JSON`)
  ancestors.add(value)
  if (Array.isArray(value)) {
    for (let index = 0; index < value.length; index += 1) {
      if (!(index in value)) throw new TypeError(`${path}[${index}]: sparse arrays are not JSON`)
      assertJSONValue(value[index], `${path}[${index}]`, ancestors)
    }
  } else {
    const prototype = Object.getPrototypeOf(value)
    if (prototype !== Object.prototype && prototype !== null) {
      throw new TypeError(`${path}: non-plain object is not JSON`)
    }
    for (const [key, child] of Object.entries(value)) {
      assertJSONValue(child, `${path}.${key}`, ancestors)
    }
  }
  ancestors.delete(value)
}

const clone = (value) => {
  assertJSONValue(value)
  return JSON.parse(JSON.stringify(value))
}

export const FIELD_CLASSIFICATIONS = new Set([
  'canonical',
  'derived-projection',
  'private-local',
  'intentionally-omitted',
  'unknown',
  'not-yet-captured',
])

// Rules are first-match. A broad rule is allowed only after every exception beneath it.
export const SIDECAR_FIELD_RULES = [
  { pattern: /^cwd(?:\.|$)/, classification: 'private-local', reason: 'absolute current-machine paths never become portable authority' },
  { pattern: /^forkProvenance(?:\.|$)/, classification: 'private-local', reason: 'today\'s fork disclosure uses legacy local Conversation and entry identities; a future adapter must resolve them to explicit portable lineage/version links rather than promoting them by inference' },
  { pattern: /^artifacts\[\]\.cwd$/, classification: 'private-local', reason: 'artifact source cwd is a current-machine path' },
  { pattern: /^workflowRuns\.\*\.outputFile$/, classification: 'private-local', reason: 'workflow outputFile is a current-machine locator' },
  { pattern: /^workflowRuns\.\*\.(?:sessionId|runKey|runTaskId|toolUseId)$/, classification: 'intentionally-omitted', reason: 'raw session/run/task/tool aliases are join-only and replaced by record-local workflow identities' },
  { pattern: /^workflowRuns\.\*\.agents\.\*\.agentId$/, classification: 'intentionally-omitted', reason: 'the raw provider agent alias is join-only and replaced by a record-local actor identity' },
  { pattern: /^(?:workflowRuns|workflowRuns\.\*|workflowRuns\.\*\.agents|workflowRuns\.\*\.agents\.\*|workflowRuns\.\*\.phases|workflowRuns\.\*\.phases\.\*)$/, classification: 'derived-projection', reason: 'mutable map/container shape is a legacy latest-state projection, not duplicate portable event history' },
  { pattern: /^workflowRuns\.\*\.(?:status|summary)$/, classification: 'derived-projection', reason: 'the mutable aggregate latest state is retained only as a provenance-marked degraded projection' },
  { pattern: /^workflowRuns\.\*\.agents\.\*\.state$/, classification: 'derived-projection', reason: 'the mutable agent latest state is retained only as a provenance-marked degraded projection' },
  { pattern: /^workflowRuns\.\*\.(?:workflowName|description)$/, classification: 'canonical', reason: 'unique workflow semantics are retained on the record-local workflow node' },
  { pattern: /^workflowRuns\.\*\.(?:error|startedAt|endedAt)$/, classification: 'derived-projection', reason: 'run-level mutable summary metadata remains a degraded legacy projection until an ordered run activity fact exists' },
  { pattern: /^workflowRuns\.\*\.usage(?:\.(?:totalTokens|toolUses|durationMs|toolUsesObserved|inputTokens|cachedInputTokens|outputTokens|reasoningOutputTokens))?$/, classification: 'derived-projection', reason: 'run-level cumulative usage is mutable summary data; exact workflow-agent activity observations remain authoritative' },
  { pattern: /^workflowRuns\.\*\.phases\.\*\.(?:index|title)$/, classification: 'canonical', reason: 'phase identity is reminted while its ordinal relation and title remain portable facts' },
  { pattern: /^workflowRuns\.\*\.agents\.\*\.(?:index|label|phaseIndex|phaseTitle|model|attempt|lastToolName|lastToolSummary|promptPreview|tokens|toolCalls|resultPreview|error|durationMs|startedAt|endedAt)$/, classification: 'canonical', reason: 'unique workflow-agent semantics are retained with exact-activity or degraded-summary provenance' },
  { pattern: /^workflowRuns\.\*\.agents\.\*\.toolEvents(?:\[\])?(?:\.(?:name|target|at))?$/, classification: 'derived-projection', reason: 'bounded mutable UI tool summaries do not become duplicate ordered tool events; exact workflow-owned activity rows remain authoritative' },

  // Activity disposition depends on `kind`: state/identity/tokens/context can be canonical while
  // tool/compaction/interjection rows are deliberately excluded duplicate projections. This
  // path-only oracle cannot express that predicate, so even shared identity/order leaves remain a
  // conservative explicit gap; kind-aware adapter fixtures prove the selected behavior instead.
  { pattern: /^agentActivity\[\]\.(?:id|captureOrdinal)$/, classification: 'not-yet-captured', reason: 'path-only classification cannot distinguish selected canonical activity kinds from deliberately excluded duplicate projections' },
  { pattern: /^agentActivity(?:\[\])?(?:\.|$)/, classification: 'not-yet-captured', reason: 'unselected provider/model, usage, guidance and lifecycle fields remain outside the current adapter; derivation parity is not proven' },
  { pattern: /^captureOrdinalHighWatermark$/, classification: 'derived-projection', reason: 'allocator recovery metadata preserves monotonic writes but is not itself a Conversation event' },
  { pattern: /^(?:title|titleSource|updatedAt)$/, classification: 'not-yet-captured', reason: 'manual title provenance and recency are durable source facts with no canonical mapping yet' },
  { pattern: /^context(?:Model|Tokens|Window)$/, classification: 'not-yet-captured', reason: 'the adapter does not map these persisted context facts or prove a parity derivation' },
  { pattern: /^subagents\.\*\.(?:durationMs|lastToolName|summary|toolUses|toolUsesObserved)$/, classification: 'not-yet-captured', reason: 'the adapter does not preserve these persisted lifecycle/tool summary facts' },

  { pattern: /^messages\[\]\.verifiedKnowledgeReceipt$/, classification: 'private-local', reason: 'the content-free diagnostic binds local Conversation, workspace, transcript-entry, and tool coordinates; a portable adapter must decode, revalidate, and remint those coordinates instead of forwarding its canonical bytes' },
  { pattern: /^messages\[\]\.learnedSkillApplicationReceipt$/, classification: 'private-local', reason: 'the content-free application receipt binds local Conversation, turn, user-entry, Workspace, and lifecycle coordinates; a portable adapter must decode, revalidate, and remint those coordinates instead of forwarding its canonical bytes' },
  { pattern: /^messages\[\]\.helpConsultationTurnID$/, classification: 'intentionally-omitted', reason: 'the raw provider turn handle is local correlation for the signed Help receipt and must be reminted before any portable mapping' },
  { pattern: /^messages\[\]\.helpConsultation(?:Receipt|CorpusID|ClaimCount)$/, classification: 'not-yet-captured', reason: 'the durable signed Help consultation fact has no portable canonical mapping yet; its system-row text remains visible but is not a structured export claim' },
  { pattern: /^messages\[\]\.(?:kind|text|toolUseId|toolName|toolResult|toolIsError|toolState|compactionTrigger|compactionPreTokens|compactionPostTokens)$/, classification: 'canonical', reason: 'mapped to an ordered canonical event with explicit result/state provenance' },
  { pattern: /^messages\[\]\.id$/, classification: 'canonical', reason: 'persisted record-local row identity supplies stable canonical event identity and refinement links' },
  { pattern: /^messages\[\]\.(?:captureOrdinal|toolResultCaptureOrdinal|toolTerminalCaptureOrdinal|interactionResponseCaptureOrdinal|interactionAcknowledgedCaptureOrdinal)$/, classification: 'canonical', reason: 'mapped as record-local order on the base event or its later refinement fact' },
  { pattern: /^messages\[\]\.(?:supersessionEventID|supersededByEntryID|supersessionCaptureOrdinal)$/, classification: 'canonical', reason: 'mapped to a record-local supersession event, replacement edge, and capture order without provider handles' },
  { pattern: /^messages\[\]\.(?:permName|permDecided|permAllowed|permAlways|questionDecided|interactionResponseStatus|interactionResponseObservedAt|interactionAcknowledgedAt|questionFreeTextResponse)$/, classification: 'canonical', reason: 'selected response content, lifecycle state, and observed selection/acknowledgement times are mapped as inert portable facts' },
  { pattern: /^messages\[\]\.interactionClosure(?:\.(?:outcome|reason|observedAt|captureOrdinal))?$/, classification: 'canonical', reason: 'an explicit terminal interaction fact and its record-local capture order are mapped without fabricating a response' },
  { pattern: /^messages\[\]\.questions(?:\[\])?(?:\.(?:question|header|multiSelect))?$/, classification: 'canonical', reason: 'retained question content is mapped to a portable historical interaction' },
  { pattern: /^messages\[\]\.questions\[\]\.options(?:\[\])?(?:\.(?:label|description|preview))?$/, classification: 'canonical', reason: 'retained answer choices are mapped to portable historical interaction content' },
  { pattern: /^messages\[\]\.questionAnswers(?:\.|$)/, classification: 'canonical', reason: 'the open-map keys are retained question text and the values are inert historical answers' },
  { pattern: /^messages\[\]\.(?:permissionId|questionId)$/, classification: 'intentionally-omitted', reason: 'legacy operative interaction handles are replaced by record-local portable interaction identities' },
  { pattern: /^messages\[\]\.(?:providerFrameUUID|supersededByFrameUUID)$/, classification: 'intentionally-omitted', reason: 'raw provider frame correlation is replaced by record-local event and replacement identities' },
  { pattern: /^subagents\.\*\.(?:startedCaptureOrdinal|endedCaptureOrdinal)$/, classification: 'derived-projection', reason: 'mutable subagent boundary summaries derive from selected agentActivity observations rather than becoming duplicate event history' },
  { pattern: /^subagents\.\*\.(?:key|subagentType|task|status|startedAt|endedAt|resultPreview|parentToolUseId)$/, classification: 'canonical', reason: 'mapped to agent identity, parentage, and explicit terminal outcome facts' },
  { pattern: /^(?:messages|messages\[\]|subagents|subagents\.\*)$/, classification: 'canonical', reason: 'container for canonical facts' },

  { pattern: /^id$/, classification: 'not-yet-captured', reason: 'Conversation lineage identity is absent from the spike graph' },
  { pattern: /^modelSelection(?:\.|$)/, classification: 'not-yet-captured', reason: 'requested model/provider attribution is not mapped by the sidecar adapter' },
  { pattern: /^artifacts(?:\[\])?(?:\.|$)/, classification: 'not-yet-captured', reason: 'artifact/blob ownership is outside the current canonical subset' },
  { pattern: /^messages\[\]\.(?:guidanceState|compactionTurnID)$/, classification: 'not-yet-captured', reason: 'durable lifecycle detail is present in legacy source but not mapped' },
  { pattern: /^subagents\.\*\.(?:agentPath|taskId|tokens|toolEvents)(?:\[\])?(?:\.|$)/, classification: 'not-yet-captured', reason: 'durable subagent provenance/usage detail is present but not mapped' },
]

export function classifySidecarField(path) {
  const rule = SIDECAR_FIELD_RULES.find((candidate) => candidate.pattern.test(path))
  return rule ? { path, classification: rule.classification, reason: rule.reason } : null
}

const MAP_PATHS = new Set(['subagents', 'workflowRuns', 'workflowRuns.*.agents'])

export function observedSidecarFields(value) {
  const observed = new Set()
  const visit = (node, path = '') => {
    if (Array.isArray(node)) {
      const itemPath = `${path}[]`
      observed.add(itemPath)
      for (const item of node) visit(item, itemPath)
      return
    }
    if (!node || typeof node !== 'object') return
    for (const [key, child] of Object.entries(node)) {
      const fieldPath = path ? `${path}.${key}` : key
      observed.add(fieldPath)
      if (MAP_PATHS.has(path)) {
        const wildcard = `${path}.*`
        observed.delete(fieldPath)
        observed.add(wildcard)
        visit(child, wildcard)
      } else {
        visit(child, fieldPath)
      }
    }
  }
  visit(value)
  return [...observed].sort()
}

export function auditSidecarFields(sidecars) {
  const fields = new Set(sidecars.flatMap(observedSidecarFields))
  const classified = []
  const unclassified = []
  for (const path of [...fields].sort()) {
    const result = classifySidecarField(path)
    if (result) classified.push(result)
    else unclassified.push(path)
  }
  return { classified, unclassified }
}

// Generated from the four reviewed 2026-08-02 derivatives. Public tests pin this inventory rather
// than opening the external evidence checkout. Updating a reviewed fixture requires regenerating
// this list and reclassifying every new path; an absent rule therefore fails closed.
export const REVIEWED_SIDECAR_OBSERVED_FIELDS = [
  'agentActivity', 'agentActivity[]', 'agentActivity[].agentID',
  'agentActivity[].agentLabel', 'agentActivity[].at', 'agentActivity[].cachedInputTokens',
  'agentActivity[].compactionTrigger', 'agentActivity[].contextTokens',
  'agentActivity[].contextWindow', 'agentActivity[].detail', 'agentActivity[].id',
  'agentActivity[].inputTokens', 'agentActivity[].kind', 'agentActivity[].modelID',
  'agentActivity[].outputTokens', 'agentActivity[].phase', 'agentActivity[].providerAccess',
  'agentActivity[].reasoningOutputTokens', 'agentActivity[].toolTarget',
  'agentActivity[].turnID', 'artifacts', 'artifacts[]', 'artifacts[].conversationTitle',
  'artifacts[].createdAt', 'artifacts[].cwd', 'artifacts[].origin', 'artifacts[].revisions',
  'artifacts[].source', 'artifacts[].title', 'artifacts[].type', 'artifacts[].updatedAt',
  'contextModel', 'contextTokens', 'contextWindow', 'cwd', 'id', 'messages', 'messages[]',
  'messages[].compactionPostTokens', 'messages[].compactionPreTokens',
  'messages[].compactionTrigger', 'messages[].compactionTurnID', 'messages[].guidanceState',
  'messages[].id', 'messages[].kind', 'messages[].permAllowed', 'messages[].permDecided',
  'messages[].permName', 'messages[].permissionId', 'messages[].providerFrameUUID',
  'messages[].questionDecided', 'messages[].questionId', 'messages[].text',
  'messages[].toolIsError', 'messages[].toolName', 'messages[].toolResult',
  'messages[].toolState', 'messages[].toolUseId', 'modelSelection', 'modelSelection.access',
  'modelSelection.modelID', 'subagents', 'subagents.*', 'subagents.*.agentPath',
  'subagents.*.durationMs', 'subagents.*.endedAt', 'subagents.*.key',
  'subagents.*.lastToolName', 'subagents.*.resultPreview', 'subagents.*.startedAt',
  'subagents.*.status', 'subagents.*.subagentType', 'subagents.*.summary',
  'subagents.*.task', 'subagents.*.taskId', 'subagents.*.tokens',
  'subagents.*.toolEvents', 'subagents.*.toolEvents[]', 'subagents.*.toolEvents[].at',
  'subagents.*.toolEvents[].name', 'subagents.*.toolEvents[].target',
  'subagents.*.toolUses', 'subagents.*.toolUsesObserved', 'title', 'titleSource', 'updatedAt',
  'workflowRuns', 'workflowRuns.*', 'workflowRuns.*.agents', 'workflowRuns.*.agents.*',
  'workflowRuns.*.agents.*.agentId', 'workflowRuns.*.agents.*.attempt',
  'workflowRuns.*.agents.*.endedAt', 'workflowRuns.*.agents.*.index',
  'workflowRuns.*.agents.*.label', 'workflowRuns.*.agents.*.lastToolName',
  'workflowRuns.*.agents.*.lastToolSummary', 'workflowRuns.*.agents.*.model',
  'workflowRuns.*.agents.*.phaseIndex', 'workflowRuns.*.agents.*.phaseTitle',
  'workflowRuns.*.agents.*.promptPreview', 'workflowRuns.*.agents.*.startedAt',
  'workflowRuns.*.agents.*.state', 'workflowRuns.*.agents.*.tokens',
  'workflowRuns.*.description', 'workflowRuns.*.endedAt', 'workflowRuns.*.outputFile',
  'workflowRuns.*.runKey', 'workflowRuns.*.runTaskId', 'workflowRuns.*.startedAt',
  'workflowRuns.*.status', 'workflowRuns.*.summary', 'workflowRuns.*.toolUseId',
  'workflowRuns.*.workflowName',
]

// These optional Codable leaves are part of the current production sidecar contract but did not
// occur in the four sanitized 2026-08-02 derivatives. Keep them separate from the observed corpus
// inventory so evidence never mislabels schema review as real-corpus observation.
export const REVIEWED_SIDECAR_PRODUCTION_FIELDS = [
  'captureOrdinalHighWatermark',
  'forkProvenance', 'forkProvenance.kind',
  'forkProvenance.sourceConversationID', 'forkProvenance.sourceTitleSnapshot',
  'forkProvenance.forkPointEntryID', 'forkProvenance.createdAt',
  'messages[].captureOrdinal',
  'messages[].supersededByFrameUUID',
  'messages[].supersessionEventID', 'messages[].supersededByEntryID',
  'messages[].supersessionCaptureOrdinal',
  'messages[].toolResultCaptureOrdinal', 'messages[].toolTerminalCaptureOrdinal',
  'messages[].verifiedKnowledgeReceipt',
  'messages[].learnedSkillApplicationReceipt',
  'messages[].helpConsultationReceipt', 'messages[].helpConsultationCorpusID',
  'messages[].helpConsultationClaimCount', 'messages[].helpConsultationTurnID',
  'messages[].permAlways',
  'messages[].interactionResponseStatus', 'messages[].interactionResponseObservedAt',
  'messages[].interactionResponseCaptureOrdinal',
  'messages[].interactionAcknowledgedAt', 'messages[].interactionClosure',
  'messages[].interactionAcknowledgedCaptureOrdinal',
  'messages[].interactionClosure.outcome', 'messages[].interactionClosure.reason',
  'messages[].interactionClosure.observedAt', 'messages[].interactionClosure.captureOrdinal',
  'messages[].questions', 'messages[].questions[]',
  'messages[].questions[].question', 'messages[].questions[].header',
  'messages[].questions[].multiSelect', 'messages[].questions[].options',
  'messages[].questions[].options[]', 'messages[].questions[].options[].label',
  'messages[].questions[].options[].description', 'messages[].questions[].options[].preview',
  'messages[].questionAnswers', 'messages[].questionFreeTextResponse',
  'agentActivity[].captureOrdinal',
  'subagents.*.parentToolUseId',
  'subagents.*.startedCaptureOrdinal', 'subagents.*.endedCaptureOrdinal',
  'workflowRuns.*.sessionId',
  'workflowRuns.*.usage', 'workflowRuns.*.usage.totalTokens',
  'workflowRuns.*.usage.toolUses', 'workflowRuns.*.usage.durationMs',
  'workflowRuns.*.usage.toolUsesObserved', 'workflowRuns.*.usage.inputTokens',
  'workflowRuns.*.usage.cachedInputTokens', 'workflowRuns.*.usage.outputTokens',
  'workflowRuns.*.usage.reasoningOutputTokens',
  'workflowRuns.*.error', 'workflowRuns.*.phases', 'workflowRuns.*.phases.*',
  'workflowRuns.*.phases.*.index', 'workflowRuns.*.phases.*.title',
  'workflowRuns.*.agents.*.toolCalls', 'workflowRuns.*.agents.*.resultPreview',
  'workflowRuns.*.agents.*.error', 'workflowRuns.*.agents.*.durationMs',
  'workflowRuns.*.agents.*.toolEvents', 'workflowRuns.*.agents.*.toolEvents[]',
  'workflowRuns.*.agents.*.toolEvents[].name',
  'workflowRuns.*.agents.*.toolEvents[].target',
  'workflowRuns.*.agents.*.toolEvents[].at',
]

const fieldDispositions = (classification, reason, fields) => Object.fromEntries(
  fields.map((field) => [field, { classification, reason }]),
)

const MAPPED_EVENT_REASON = 'the current root-C adapter maps this reviewed field to an ordered canonical fact'
const TRANSPORT_REASON = 'runtime discovery/transport state is intentionally outside the portable Conversation record'
const RAW_CONTROL_ID_REASON = 'the operative wire handle is replaced by a record-local portable identity'
const VALIDATED_DUPLICATE_REASON = 'capture validates this acknowledgement copy against the outbound decision; it is not a second portable fact'

// This table is intentionally exact-match rather than prefix-based. A new child beneath `input`,
// `usage`, `workflowProgress`, or any other reviewed container receives no disposition until it is
// named here. That makes wire growth fail closed instead of inheriting a false `canonical` label
// merely because its event type is known.
export const REVIEWED_CAPTURE_EVENT_FIELD_DISPOSITIONS = {
  ready: {
    ...fieldDispositions('intentionally-omitted', TRANSPORT_REASON, [
      'type', 'mode', 'provider', 'auth', 'loggedIn', 'planType',
    ]),
    ...fieldDispositions('private-local', 'the runtime working directory is a current-machine absolute path', ['cwd']),
  },
  allowlist: fieldDispositions('intentionally-omitted', TRANSPORT_REASON, ['type', 'tools']),
  model_catalog: fieldDispositions('intentionally-omitted', TRANSPORT_REASON, [
    'type', 'id', 'scope', 'models', 'models[]', 'models[].id', 'models[].label',
    'models[].isDefault', 'models[].efforts', 'models[].efforts[]',
    'models[].capabilities', 'models[].capabilities[]',
  ]),
  status: fieldDispositions('intentionally-omitted', TRANSPORT_REASON, ['type', 'id', 'status']),
  turn_started: fieldDispositions('canonical', MAPPED_EVENT_REASON, ['type', 'id']),
  session: {
    ...fieldDispositions('canonical', MAPPED_EVENT_REASON, ['type', 'id']),
    ...fieldDispositions(
      'private-local',
      'raw provider resume handles must not become portable identifiers',
      ['sessionId'],
    ),
  },
  delta: fieldDispositions('canonical', MAPPED_EVENT_REASON, ['type', 'id', 'text']),
  tool_use: {
    ...fieldDispositions('canonical', MAPPED_EVENT_REASON, [
      'type', 'id', 'toolUseId', 'parentToolUseId', 'name', 'input', 'input.command',
      'input.subagent_type', 'input.description', 'input.recipient', 'input.summary',
    ]),
    ...fieldDispositions('intentionally-omitted', RAW_CONTROL_ID_REASON, ['frameUUID']),
  },
  tool_result: {
    ...fieldDispositions('canonical', MAPPED_EVENT_REASON, [
      'type', 'id', 'toolUseId', 'parentToolUseId', 'status', 'isError', 'result',
    ]),
    ...fieldDispositions(
      'private-local',
      'one-shot daemon image handoff is consumed into conversation-owned media before capture',
      ['generatedImagePath', 'generatedImageBytes'],
    ),
  },
  usage: fieldDispositions('canonical', MAPPED_EVENT_REASON, [
    'type', 'id', 'input', 'cachedInput', 'output', 'reasoningOutput',
  ]),
  context_usage: fieldDispositions('canonical', MAPPED_EVENT_REASON, [
    // `compactionThreshold` added 2026-08-07: the provider-reported fill at which compaction runs,
    // which is normally below `contextWindow`. Canonical for the same reason the other two are —
    // it is a measured property of the turn's context, not a handle or a private detail.
    'type', 'id', 'contextTokens', 'contextWindow', 'compactionThreshold', 'model',
  ]),
  workflow_update: {
    ...fieldDispositions('canonical', MAPPED_EVENT_REASON, [
      'type', 'id', 'phase', 'taskId', 'toolUseId', 'taskType', 'subagentType',
      'description', 'summary', 'status', 'model', 'lastToolName', 'resultPreview', 'usage',
      'usage.totalTokens', 'usage.inputTokens', 'usage.cachedInputTokens',
      'usage.outputTokens', 'error',
    ]),
    ...fieldDispositions('canonical', 'the workflow fact maps to a canonical node/event while raw aliases are confined to record-local reminting', [
      // Claude workflow identity/progress plus Codex nested-agent/tool observations.
      'isWorkflowRun', 'workflowName', 'agentPath', 'parentToolUseId', 'toolEvent',
      'toolTarget',
      // Provider usage fields omitted by the current selected-subset lifecycle event.
      'usage.toolUses', 'usage.durationMs', 'usage.toolUsesObserved',
      'usage.reasoningOutputTokens',
      // The SDK forwards cumulative workflow entries as open maps. Every currently consumed leaf is
      // explicit so a future nested member cannot hide behind the container disposition.
      'workflowProgress[].type',
      'workflowProgress[].index', 'workflowProgress[].title',
      'workflowProgress[].phaseIndex', 'workflowProgress[].label',
      'workflowProgress[].phaseTitle', 'workflowProgress[].state',
      'workflowProgress[].agentId', 'workflowProgress[].model',
      'workflowProgress[].attempt', 'workflowProgress[].lastToolName',
      'workflowProgress[].lastToolSummary', 'workflowProgress[].promptPreview',
      'workflowProgress[].tokens', 'workflowProgress[].toolCalls',
      'workflowProgress[].resultPreview', 'workflowProgress[].error',
      'workflowProgress[].durationMs',
    ]),
    ...fieldDispositions('derived-projection', 'the cumulative workflow progress array is a transport container; its reviewed semantic entries become canonical facts', [
      'workflowProgress', 'workflowProgress[]',
    ]),
    ...fieldDispositions(
      'intentionally-omitted',
      'the provider item handle only correlates the parallel harness tool observation; root C has no tool-observation refinement mapping yet',
      ['toolEventID'],
    ),
    ...fieldDispositions(
      'intentionally-omitted',
      'the provider query ordinal only reconciles child usage snapshots; root C has no query-scoped usage refinement mapping yet',
      ['providerQuerySequence'],
    ),
    ...fieldDispositions(
      'private-local',
      'workflow outputFile is a current-machine locator, not portable artifact identity',
      ['outputFile'],
    ),
  },
  compact_boundary: {
    ...fieldDispositions('canonical', MAPPED_EVENT_REASON, [
      'type', 'id', 'trigger', 'preTokens', 'postTokens',
    ]),
    ...fieldDispositions(
      'intentionally-omitted',
      'the provider-local correlation sequence has no current root-C refinement mapping',
      ['compactionSequence'],
    ),
  },
  // Claude's supported PostCompact hook exposes the exact provider-authored continuity summary,
  // but the current root-C adapter maps only the compact_boundary base event. Do not call this
  // second wire event canonical until the adapter has an explicit refinement fact linking the
  // summary to that boundary. The two provider handles and the temp-file handoff locator are also
  // deliberately confined to this machine.
  compaction_summary: {
    ...fieldDispositions(
      'intentionally-omitted',
      'the current root-C adapter has no compaction-summary refinement mapping',
      [
        'type', 'id', 'trigger', 'compactionSequence', 'summary', 'summarySource',
        'summaryTruncated', 'summaryBytes',
      ],
    ),
    ...fieldDispositions(
      'private-local',
      'provider session/prompt handles and the temporary summary-file locator are local coordination state',
      ['summaryPath', 'sessionId', 'promptId'],
    ),
  },
  // The provider's own memory recall supervisor, reported so a turn influenced by a memory the user
  // never typed is no longer silent.
  //
  // Classified `intentionally-omitted`, not `canonical` and not `not-yet-captured`. Not canonical,
  // because the root-C adapter maps nothing from a recall and claiming otherwise would assert a
  // parity that does not exist. Not `not-yet-captured` either: that classification describes
  // persisted sidecar fields awaiting a mapping, and the C1.5 evidence invariant requires every
  // reviewed CAPTURE-surface field to reach a terminal disposition. A recall is a local disclosure
  // marker about how this machine's provider behaved, in the same class as `status` and `ready` —
  // it is evidence for the user, not portable Conversation content. If Mechanician's own memory
  // system later makes a recall a portable fact, this becomes canonical with an adapter mapping.
  //
  // What is absent from this list is the point. The upstream message carries an absolute
  // `path` under the auto-memory directory (or an https tenant address) and an optional `content`
  // holding the memory body verbatim. `claudeMemoryRecallEvent` drops both before an event exists:
  // `title` is a leaf name only, and `hasBody` says whether a body was supplied without reproducing
  // it. A memory body is cross-conversation user content, and copying it into every conversation
  // that recalled it would create a second, unmanaged store of exactly the thing the memory system
  // is meant to keep in one place.
  // Classified `intentionally-omitted`, not `not-yet-captured`. That classification describes
  // persisted sidecar fields awaiting a mapping, and the C1.5 evidence invariant requires every
  // reviewed CAPTURE-surface field to reach a terminal disposition. A recall is a local disclosure
  // marker about how this machine's provider behaved, in the same class as `status` and `ready` —
  // evidence for the user, not portable Conversation content.
  // The memory extraction judge's answer. Not conversation content at all: it is a control
  // response to a request the app made, carrying yes/no verdicts about sentences the app already
  // held. It names no conversation, enters no turn record, and its inputs are the user's own
  // messages which the Conversation already contains.
  memory_extract_result: fieldDispositions(
    'intentionally-omitted',
    'a control response to an app-initiated classification request, not Conversation content',
    ['type', 'id', 'verdicts', 'verdicts[]', 'verdicts[].index', 'verdicts[].keep',
     'verdicts[].topic', 'failed']),
  memory_recall: fieldDispositions(
    'intentionally-omitted',
    'a provider-behavior disclosure marker for this machine, not portable Conversation content',
    [
      'type', 'id', 'mode', 'memories', 'memories[]',
      'memories[].kind', 'memories[].title', 'memories[].scope', 'memories[].hasBody',
    ]),
  error: fieldDispositions('canonical', MAPPED_EVENT_REASON, [
    'type', 'id', 'errorKind', 'rateLimitType', 'resetsAt', 'message',
  ]),
  // The non-terminal usage warning. Same family as the `error` above and classified the same way:
  // it carries no conversation content and no user words, only the account's own allowance state,
  // and it is persisted on the transcript entry it produces so it survives relaunch.
  usage_status: fieldDispositions('canonical', MAPPED_EVENT_REASON, [
    'type', 'id', 'status', 'rateLimitType', 'limitLabel', 'utilization',
    'surpassedThreshold', 'resetsAt', 'isUsingOverage',
  ]),
  steer_ack: fieldDispositions('canonical', MAPPED_EVENT_REASON, [
    'type', 'id', 'turnId', 'steerId',
  ]),
  steer_rejected: fieldDispositions('canonical', MAPPED_EVENT_REASON, [
    'type', 'id', 'turnId', 'steerId',
  ]),
  permission_request: {
    ...fieldDispositions('canonical', MAPPED_EVENT_REASON, [
      'type', 'id', 'name', 'writeEscape', 'capability',
      'capability.name', 'capability.title', 'capability.description', 'capability.safety',
    ]),
    ...fieldDispositions('intentionally-omitted', RAW_CONTROL_ID_REASON, ['permissionId']),
    ...fieldDispositions(
      'intentionally-omitted',
      'raw approval input is operative and is replaced by an explicit portable disclosure marker',
      ['input', 'input.name'],
    ),
    ...fieldDispositions(
      'private-local',
      'permission command and workspace-escape locators can contain current-machine paths or sensitive operative input',
      ['input.command', 'writeEscape.target', 'writeEscape.workspace'],
    ),
  },
  permission_response_ack: {
    ...fieldDispositions('canonical', MAPPED_EVENT_REASON, [
      'type', 'id', 'accepted', 'message',
    ]),
    ...fieldDispositions('intentionally-omitted', RAW_CONTROL_ID_REASON, ['permissionId']),
    ...fieldDispositions('intentionally-omitted', VALIDATED_DUPLICATE_REASON, ['allow', 'always']),
  },
  question_request: {
    ...fieldDispositions('canonical', MAPPED_EVENT_REASON, [
      'type', 'id', 'questions', 'questions[]', 'questions[].question',
      'questions[].header', 'questions[].options', 'questions[].options[]',
      'questions[].options[].label', 'questions[].options[].description',
      'questions[].options[].preview', 'questions[].multiSelect',
    ]),
    ...fieldDispositions('intentionally-omitted', RAW_CONTROL_ID_REASON, ['reqId']),
  },
  question_response_ack: {
    ...fieldDispositions('canonical', MAPPED_EVENT_REASON, [
      'type', 'id', 'accepted', 'message',
    ]),
    ...fieldDispositions('intentionally-omitted', RAW_CONTROL_ID_REASON, [
      'reqId', 'responseId',
    ]),
  },
  interaction_closed: {
    ...fieldDispositions('canonical', MAPPED_EVENT_REASON, [
      'type', 'id', 'interactionKind', 'outcome', 'reason',
    ]),
    ...fieldDispositions('intentionally-omitted', RAW_CONTROL_ID_REASON, ['requestId']),
  },
  done: fieldDispositions('canonical', MAPPED_EVENT_REASON, ['type', 'id', 'interrupted']),
}

// Outbound control messages share a container but not a vocabulary. Keep every request type exact
// so adding a field to one interaction cannot inherit a disposition from another. User-authored
// answer maps are the sole intentionally open value: their dynamic keys are the retained question
// text, not protocol member names.
export const REVIEWED_CAPTURE_OUTBOUND_REQUEST_FIELD_DISPOSITIONS = {
  steer: {
    ...fieldDispositions('canonical', MAPPED_EVENT_REASON, ['type', 'prompt']),
    ...fieldDispositions('intentionally-omitted', RAW_CONTROL_ID_REASON, [
      'id', 'turnId', 'steerId',
    ]),
  },
  permission_response: {
    ...fieldDispositions('canonical', MAPPED_EVENT_REASON, [
      'type', 'allow', 'always', 'message',
    ]),
    ...fieldDispositions('intentionally-omitted', RAW_CONTROL_ID_REASON, [
      'id', 'permissionId', 'responseId',
    ]),
  },
  question_response: {
    ...fieldDispositions('canonical', MAPPED_EVENT_REASON, [
      'type', 'answers', 'response',
    ]),
    ...fieldDispositions('intentionally-omitted', RAW_CONTROL_ID_REASON, [
      'id', 'reqId', 'responseId',
    ]),
  },
  interrupt: {
    ...fieldDispositions('canonical', MAPPED_EVENT_REASON, ['type']),
    ...fieldDispositions('intentionally-omitted', RAW_CONTROL_ID_REASON, ['id', 'turnId']),
  },
}

const REVIEWED_CAPTURE_ENVELOPE_FIELD_DISPOSITIONS = {
  prompt: { classification: 'canonical', reason: 'accepted user input becomes a canonical event' },
  promptObservedAt: { classification: 'canonical', reason: 'explicit prompt acceptance observation time is preserved; unknown remains null' },
  producer: { classification: 'canonical', reason: 'capture envelope records the producing implementation' },
  'producer.name': { classification: 'canonical', reason: 'capture envelope records the producing implementation' },
  'producer.version': { classification: 'canonical', reason: 'capture envelope records the producing implementation' },
  'producer.build': { classification: 'canonical', reason: 'capture envelope records the producing implementation' },
  profile: { classification: 'canonical', reason: 'capture envelope declares the native profile/version' },
  'profile.id': { classification: 'canonical', reason: 'capture envelope declares the native profile/version' },
  'profile.version': { classification: 'canonical', reason: 'capture envelope declares the native profile/version' },
  events: { classification: 'canonical', reason: 'capture order is authoritative' },
  'events[]': { classification: 'canonical', reason: 'capture order is authoritative' },
  'events[].seq': { classification: 'derived-projection', reason: 'array order is the canonical normalization of capture sequence' },
  'events[].observedAt': { classification: 'canonical', reason: 'captured as approximate observation time with provenance' },
  'events[].event': { classification: 'canonical', reason: 'container for one reviewed provider event' },
  outboundRequests: { classification: 'canonical', reason: 'capture records user-to-provider steering requests actually sent on the wire' },
  'outboundRequests[]': { classification: 'canonical', reason: 'container for one captured outbound request' },
  'outboundRequests[].afterEventSequence': { classification: 'derived-projection', reason: 'anchors the outbound request in authoritative capture order' },
  'outboundRequests[].observedAt': { classification: 'canonical', reason: 'capture observation time is retained with provenance' },
  'outboundRequests[].request': { classification: 'canonical', reason: 'container for one type-reviewed outbound request' },
  quiescence: { classification: 'intentionally-omitted', reason: 'fixture capture-control evidence validates completeness but is not Conversation content' },
  'quiescence.protocolVersion': { classification: 'intentionally-omitted', reason: 'fixture capture-control protocol metadata is not Conversation content' },
  'quiescence.sequence': { classification: 'intentionally-omitted', reason: 'fixture capture-control sequence is not Conversation content' },
  'quiescence.observedAt': { classification: 'intentionally-omitted', reason: 'fixture capture-control observation is not Conversation content' },
  'quiescence.root': { classification: 'intentionally-omitted', reason: 'validated duplicate terminal summary is not a second canonical fact' },
  'quiescence.root.type': { classification: 'intentionally-omitted', reason: 'validated duplicate terminal summary is not a second canonical fact' },
  'quiescence.root.id': { classification: 'intentionally-omitted', reason: 'validated duplicate terminal summary is not a second canonical fact' },
  'quiescence.root.interrupted': { classification: 'intentionally-omitted', reason: 'validated duplicate terminal summary is not a second canonical fact' },
  'quiescence.children': { classification: 'intentionally-omitted', reason: 'validated duplicate child summary is not a second canonical fact' },
  'quiescence.children[]': { classification: 'intentionally-omitted', reason: 'validated duplicate child summary is not a second canonical fact' },
  'quiescence.children[].id': { classification: 'intentionally-omitted', reason: 'validated duplicate child summary is not a second canonical fact' },
  'quiescence.children[].parentId': { classification: 'intentionally-omitted', reason: 'validated duplicate child summary is not a second canonical fact' },
  'quiescence.children[].state': { classification: 'intentionally-omitted', reason: 'validated duplicate child summary is not a second canonical fact' },
  'quiescence.children[].stateHistory': { classification: 'intentionally-omitted', reason: 'validated duplicate child summary is not a second canonical fact' },
  'quiescence.children[].stateHistory[]': { classification: 'intentionally-omitted', reason: 'validated duplicate child summary is not a second canonical fact' },
}

export function classifyReviewedCaptureField(path, eventType = null, outboundType = null) {
  const envelope = REVIEWED_CAPTURE_ENVELOPE_FIELD_DISPOSITIONS[path]
  if (envelope) return { path, ...envelope }
  const outboundPrefix = 'outboundRequests[].request.'
  if (path.startsWith(outboundPrefix) && outboundType) {
    const disposition = REVIEWED_CAPTURE_OUTBOUND_REQUEST_FIELD_DISPOSITIONS[outboundType]
      ?.[path.slice(outboundPrefix.length)]
    return disposition ? { path, ...disposition } : null
  }
  const eventPrefix = 'events[].event.'
  if (!path.startsWith(eventPrefix) || !eventType) return null
  const disposition = REVIEWED_CAPTURE_EVENT_FIELD_DISPOSITIONS[eventType]
    ?.[path.slice(eventPrefix.length)]
  return disposition ? { path, ...disposition } : null
}

// Reviewed capture surface: the fields emitted by the nine checked-in fixtures, augmented with
// the complete provider-neutral workflow_update shape currently consumed from agentd and
// codex-workflows. It is not a claim that every agentd event family has passed format review.
export const REVIEWED_CAPTURE_ENVELOPE_FIELDS = [
  'prompt', 'promptObservedAt',
  'producer', 'producer.name', 'producer.version', 'producer.build',
  'profile', 'profile.id', 'profile.version',
  'events', 'events[]', 'events[].seq', 'events[].observedAt', 'events[].event',
  'outboundRequests', 'outboundRequests[]', 'outboundRequests[].afterEventSequence',
  'outboundRequests[].observedAt', 'outboundRequests[].request',
  'quiescence', 'quiescence.protocolVersion', 'quiescence.sequence',
  'quiescence.observedAt', 'quiescence.root', 'quiescence.root.type',
  'quiescence.root.id', 'quiescence.root.interrupted', 'quiescence.children',
  'quiescence.children[]', 'quiescence.children[].id', 'quiescence.children[].parentId',
  'quiescence.children[].state', 'quiescence.children[].stateHistory',
  'quiescence.children[].stateHistory[]',
]

export const REVIEWED_CAPTURE_EVENT_FIELDS = Object.fromEntries(
  Object.entries(REVIEWED_CAPTURE_EVENT_FIELD_DISPOSITIONS).map(([eventType, dispositions]) =>
    [eventType, Object.keys(dispositions)]),
)

export const REVIEWED_CAPTURE_OUTBOUND_REQUEST_FIELDS = Object.fromEntries(
  Object.entries(REVIEWED_CAPTURE_OUTBOUND_REQUEST_FIELD_DISPOSITIONS)
    .map(([outboundType, dispositions]) => [outboundType, Object.keys(dispositions)]),
)

// These pins make the hand-reviewed recursive vocabulary above fail on capture-source drift.
// Changing a fixture or any reviewed production producer requires re-auditing this inventory
// before the oracle can pass again.
export const REVIEWED_CAPTURE_SOURCE_PINS = {
  // The production sources define the additional reviewed surface and the bounded helper-owned
  // shapes discussed below. Pinning whole files is deliberately conservative: any producer change
  // forces a human re-audit before format-review evidence can turn green again.
  // Re-audited 2026-08-07 for the compaction-recovery change (narrowed cascade abort + one
  // same-session retry). Every `emit({…})` shape in the file is byte-identical before and after;
  // the change is control flow and logging only, so the capture vocabulary above is unaffected.
  //
  // Re-audited 2026-09-01 for the Memory removal. Checked mechanically, the same way as the
  // 0.26.7 entry above: every `emit({…})` block extracted from both revisions and compared by
  // top-level field set. agentd.mjs went from 348 blocks and 144 distinct shapes to 325 and 131;
  // claude-message-events.mjs and tool-surface.mjs contain no emit block on either side. NO SHAPE
  // WAS ADDED and no surviving shape gained, lost or renamed a field. The thirteen shapes that are
  // no longer produced are the retired subsystem's own wire — memory_extract/select/summarize/
  // research/chat results, memory_recall_request, and the recall disclosure spread. A producer
  // that stops existing is what these pins exist to surface, not something they forbid.
  //
  // Re-audited 2026-09-02 for a one-line follow-up to that removal: `agentd.mjs` still imported
  // `claudeMemoryRecallEvent`, a name `claude-message-events.mjs` no longer exports. That parses,
  // so `node --check` passed; it fails at LINK time, so the daemon did not start and every test
  // that spawns it reported a ready timeout. The fix deletes the dead import and nothing else.
  // Audited the same mechanical way: 325 emit blocks before and after, and the set of top-level
  // field sets is identical, so no shape was added, removed, or renamed. The same pass drops one
  // stale comment line in `claude-compaction-summary.mjs` that named the deleted memory-delivery
  // ledger; that file's only export is unchanged and it contains no emit block on either side.
  //
  // Re-audited again 2026-08-07 for the oversized-bundled-skill demotion and its window gate.
  // Checked emit by emit: the additions are two module constants, one system-prompt append string
  // (now conditioned on the settings object this turn already built), one import, four fields added
  // to an existing `log()` line, a skill-name capture that runs after an unchanged
  // `emit({ ...toolEvent, id })`, and one control-flow branch that calls the existing
  // `emitTerminalCompactionFailure`. No emit gains, loses, or renames a field.
  //
  // Re-audited 2026-08-08 for the 0.26.7 changes: the Stop-before-preparation guards, the Codex
  // dynamic-tool widening with its developer-instruction protocol, the route-aware context window,
  // and the write-lease removal. Verified mechanically rather than by reading: every `emit({…})`
  // block was extracted from both revisions and compared by top-level field set. 248 blocks and 147
  // distinct shapes before and after, with no shape added, removed, or renamed. The tool_catalog
  // emit changed the VALUES it reports (the filtered Codex specs and the real MCP server list
  // instead of the whole tool table) but not its fields, and the deleted write-lease surface was
  // `log()` output, never an emit. The capture vocabulary above is therefore unaffected.
  //
  // Re-audited 2026-08-08 for FR-211 (remembered approvals keyed on the engine's own permission
  // rule, and the acknowledgement reporting what was actually remembered). Same mechanical check:
  // 248 emit blocks and 147 distinct shapes before and after, nothing added, removed, or renamed.
  // `permission_response_ack` keeps its exact field set; only the VALUE of `always` changed, from
  // echoing the request to reporting whether a grant was stored.
  //
  // Re-audited 2026-08-08 for FR-222 (deleting the unreachable `reject_prompt` outcome and the
  // `resumed` flag whose false case produced it). Same mechanical check: 248 emit blocks and 147
  // distinct shapes before and after, nothing added, removed, or renamed. The change removes an
  // argument from two `claudeContextDecision` call sites and emits nothing new.
  //
  // Re-audited 2026-08-08 for FR-224's subtraction reporting. Unlike the three re-audits above, this
  // one DOES change the emit surface: 248 blocks and 147 shapes become 249 and 148, and the addition
  // is one new event type, `subtraction`, carrying {lane, subject, reason, names, count, message,
  // duration} plus an optional turn id. Nothing existing gained, lost, or renamed a field.
  //
  // Deliberately NOT added to the reviewed capture vocabulary above. That vocabulary is a curated
  // subset of 28 event types, and it does not classify `history_reduced` either, which is this
  // event's direct precedent and is equally durable and user-facing. Adding one and not the other
  // would misrepresent the capture surface as broader than it is. If the document format later
  // takes in maintenance markers, `history_reduced` and `subtraction` should be classified in the
  // same pass, with the same dispositions: identifiers and counts are safe, `message` is
  // app-authored prose and belongs in the same bucket as other display strings.
  //
  // Re-audited 2026-08-08 again, for the second batch of FR-224 call sites (credential boundary,
  // dropped MCP servers on both preparation paths, the Codex sandbox-approval channel and the
  // Codex plan-mode decline). No NEW event shape: 249 blocks become 247 and 148 shapes become 147
  // because two `emit({type:'info', id: ctx.id, message})` announcements were REPLACED by
  // `emitSubtraction`, which carries the same sentence to the transcript and adds the structured
  // record. `info` itself remains emitted from seven other sites, including the history-reduction
  // pair, so the type is not retired. One reason string was added to the frozen vocabulary
  // (`credential_boundary`); the Swift mirror gained the matching case, which the cross-language
  // test caught by name before it could ship.
  //
  // Re-audited 2026-08-08 for the claude-api skill-visibility marking. The `commands` event gains an
  // optional per-command `agentInvocable: false` on a lane that demoted a skill to
  // user-invocable-only. `commands` is not classified in the reviewed capture vocabulary above, and
  // the addition is a boolean on an existing payload rather than a new event type or a new
  // top-level field, so the emit-shape comparison is unchanged. No `subtraction` event is emitted
  // for this: it is a standing property of the lane, not a per-turn occurrence.
  //
  // Re-audited 2026-08-09 for FR-216's preflight measurement. This one adds no capture surface at
  // all: the change is a `log()` line plus a pure helper naming why a turn had to block on
  // `getContextUsage()`. Verified mechanically rather than by reading, extracting every `emit({…})`
  // block from both revisions and comparing top-level field sets — 247 blocks and 98 distinct
  // shapes on each side, none added, none removed, none renamed. Deliberately a log rather than an
  // event: it is developer measurement for choosing a threshold, not a fact the user is owed.
  //
  // Re-audited 2026-08-11 for bounded background-process discovery and pre-kill identity
  // validation, including the ps timeout/error path and the pre-turn polling gate.
  // `background_processes` retains {type, processes}; `background_process_killed` retains
  // {type, id, pid}; and `control_error` retains {type, id, message}. The scheduling and lifecycle
  // changes add no event type or top-level field, so the capture vocabulary is unchanged.
  //
  // Re-audited 2026-08-11 for the Claude terminal-usage cache repair. The emit-block count changes
  // from 248 to 249 solely because `conversation_reset` now persists its declared successor with
  // {type: 'session', id, sessionId}, an exact duplicate of the already-reviewed `session` shape
  // above; the generic session emit keeps that same shape and no event gains or loses a field.
  // Existing `context_usage.model` now prefers the SDK's canonical serving id when present, which
  // improves the value's provenance without changing the reviewed field or classification. All
  // other additions are cache/control state, tests, and developer logs, not capture vocabulary.
  // Re-audited again for bounded Codex App Server restarts: the two existing `ready` and
  // {type: 'info', message} publications move into the common scheduler, while the open-circuit
  // branch uses those exact already-reviewed shapes. Connect recovery moves the existing
  // login_started/login_url publications behind an explicit provider-start attempt and uses the
  // existing id-bearing login_ok/login_error shapes for terminal ownership. Field vocabulary is
  // unchanged.
  // Re-audited again for inactive Codex App Server residency. `provider_residency` is an inbound,
  // app-authored lifecycle advisory and therefore adds no captured provider event. Idle release,
  // wake, busy leases, and restart isolation are control flow plus developer logs. Login, logout,
  // catalog, OAuth, ready, info, and control-error paths retain their existing event types and
  // top-level fields; the OAuth provider-exit fix removes a duplicate terminal rather than adding a
  // shape. The reviewed capture vocabulary is unchanged.
  // Re-audited again for the Claude cache-identity hardening. The changes only make catalog and
  // context-model eligibility fail closed before the existing live getContextUsage fallback; they
  // add no emit call and change no event field, type, or value. The reviewed vocabulary is
  // unchanged.
  // Re-audited again for background Stop publication reconciliation. The existing
  // `background_processes` event retains {type, processes}, and `background_process_killed`
  // retains {type, id, pid}; only post-Stop unchanged-snapshot coalescing changed. No event type or
  // top-level field was added, removed, or renamed.
  // Re-audited 2026-08-13 for the post-authentication MCP readiness boundary and ordered account
  // reload. The new `mcp_credentials_changed`, `mcp_readiness_proof`, `mcp_reconcile_*`, and
  // `mcp_reload_*` messages are app-daemon control-plane events, outside this deliberately curated
  // provider-turn vocabulary, as are the pre-existing MCP authorization messages they coordinate.
  // `session_invalidated` gains no field (one new site emits its existing id-only shape, and one
  // site adds the existing `mcp_credentials_changed` reason value). `status` retains {type, id,
  // status}. `ready` alone gains optional `accountInstanceId`, a current-machine account epoch; it
  // is absent from all nine reviewed fixtures, just like the existing optional `accountStatus`, and
  // therefore does not enlarge their observed field inventory. No canonical turn-record field is
  // added, removed, or renamed.
  // Re-audited 2026-08-13 for bounded Claude/Vertex no-output recovery and provider process-tree
  // retirement. Every changed `agentd.mjs` hunk was inspected: no `emit({…})` call, event type, or
  // top-level event field was added, removed, or renamed. The existing `history_reduced` event gains
  // only the `provider_no_output` reason value, and the existing error publication can now carry a
  // `provider_no_output` providerError with diagnostic/replay evidence. `providerError` and its
  // children were already outside this fixture-observed curated vocabulary, so this does not widen
  // the reviewed field claim above. Watchdogs, replay eligibility, session retirement, process-group
  // ownership, and their diagnostic logs are control flow rather than captured provider events.
  //
  // Re-audited 2026-08-13 for the measured context-window memory. Verified mechanically by
  // extracting every `emit({…})` block from both revisions with a CHARACTER-level brace/string
  // scanner and comparing top-level field sets: 309 blocks and 121 distinct shapes become 311 and
  // 122. The single addition is `{type, windows}`, emitted from two sites (route ready, and a turn
  // that measured a new window). Nothing existing gained, lost, or renamed a field.
  //
  // Note on the counts: they do not continue the 247/98 and 248/147 series quoted in the notes
  // above, because those used a line-based extractor that collapsed every one-line `emit({…})` into
  // an empty shape. The numbers here come from the same scanner applied to BOTH revisions, so the
  // delta is exact even though the absolute totals are not comparable to the older entries.
  //
  // `context_windows` is deliberately NOT added to the reviewed capture vocabulary above. It has no
  // conversation id and never enters a turn record; it is a per-route cache snapshot in the same
  // class as `commands`, `login_ok` and `info`, none of which that vocabulary classifies. The
  // measurement was deliberately kept OFF the `ready` event for this reason: `ready` is classified
  // above, so a field there would have needed its own disposition, and a cache that changes
  // mid-session does not belong on a lifecycle event. The one field it carries is a map from model
  // id to an integer window, which is provider catalog data with no user content in it.
  // Re-audited 2026-08-14 for the Claude memory-recall disclosure. Same character-level
  // brace/string scanner applied to both revisions: 311 blocks and 139 distinct shapes become 312
  // and 140. The single addition is `{...recall, id}`, emitted from one site in the Claude stream
  // loop beside `compact_boundary`. No existing block gained, lost, or renamed a field, and nothing
  // was removed. `claude-message-events.mjs` gains the pure normalizer behind that spread
  // (`claudeMemoryRecallEvent`) and no other export changes behavior.
  //
  // Re-audited 2026-08-14 for the memory extraction judge. Same scanner both revisions: 312 blocks
  // and 140 shapes become 315 and 142. The two additions are `{type, id, verdicts}` and its failure
  // form `{type, id, verdicts, failed}`, emitted from one bounded classifier that runs only when the
  // app asks. No existing block changed. Classified `intentionally-omitted`: it is a control
  // response about sentences the app already held, not Conversation content.
  //
  // This revision of `agentd.mjs` also carries an unrelated route-aware first-response timeout.
  // It was re-scanned for this pin: it adds no `emit` block and touches no event field, so it does
  // not widen the reviewed capture surface.
  //
  // The event is classified `not-yet-captured` above rather than `canonical`, because it is durable
  // in the sidecar but the root-C adapter maps none of it. Two upstream fields are deliberately
  // dropped before the event exists rather than classified here: the memory's absolute `path` (a
  // current-machine location, the same class as `ready.cwd`) and its `content` (the memory body
  // itself). Only a leaf `title` and a `hasBody` flag survive. This is the one place where the
  // narrower wire is a privacy decision and not merely an omission, so it is stated at the pin.
  // Re-audited 2026-08-14 for the memory span selector, which supersedes the judge above. Same
  // character-level brace/string scanner applied to BOTH revisions: 315 blocks and 121 distinct
  // shapes become 318 and 123. (These totals use this scanner on both sides; as noted earlier they
  // are not comparable to the older line-based series, but the delta is exact.) The two additions
  // are `{type, id, spans}` and its failure form `{type, id, spans, failed}`, emitted from one
  // bounded selector that runs only when the app asks. No existing block gained, lost, or renamed
  // a field, and nothing was removed.
  //
  // Classified `intentionally-omitted` for the same reason as the judge: it is a control response
  // to a request the app made, not Conversation content, and it never enters a turn record.
  //
  // The REQUEST side is the part worth stating at the pin. `memory_select` carries a batch of the
  // user's own message texts — more than the judge's extracted sentences did. Never the assistant's
  // replies, never tool output, never file contents, and nothing is retained: the daemon holds the
  // batch only for the duration of one bounded query. The returned spans are useless without the
  // app's verification step, which discards anything that is not a literal substring of a message
  // the user actually sent, so this lane cannot widen what memory may contain — only what it may
  // notice.
  //
  // Re-audited 2026-08-14 for the no-output liveness-ledger fix. Same character-level scanner on
  // BOTH revisions: 318 blocks and 144 distinct shapes before and after, with nothing added,
  // removed, or renamed. (144 rather than the 123 quoted above is this scanner counting spreads
  // and computed keys as distinct fields; the point of a same-scanner run is the delta, which is
  // zero.) The change is two statements in the Claude stream loop — the ledger now asks
  // `isProviderResponseActivity` directly instead of reading the one-shot watchdog's return value —
  // plus one `log()` field that reports the same predicate. No emit is reached by either edit, so
  // the reviewed capture surface is unchanged.
  //
  // Re-audited 2026-08-14 for the memory FACT pass, which replaces span selection. Same scanner on
  // BOTH revisions: 318 blocks and 144 distinct shapes before and after, nothing added, removed, or
  // renamed. The `memory_select_result` emit keeps its `{type, id, spans}` top-level shape; what
  // changed is INSIDE the array, where each item gains a `fact` alongside `message`/`topic`/`quote`.
  //
  // That addition is worth stating even though the emit shape did not move, because it is the one
  // field on this lane the model AUTHORS rather than copies. It is still classified
  // `intentionally-omitted`: a control response to a request the app made, never Conversation
  // content, and it does not enter a turn record. It is also not yet a memory when it crosses this
  // wire — the app stores it only if the `quote` beside it is a literal substring of a message the
  // user actually sent, so a fact the daemon emits and the app refuses leaves no trace anywhere.
  //
  // The REQUEST side is unchanged from the span selector: a batch of the user's own message texts,
  // never the assistant's replies, tool output, or file contents, retained only for one query.
  //
  // Re-audited 2026-08-14 for the selection timeout being reported instead of absorbed. Same
  // scanner on BOTH revisions: 318 blocks and 144 distinct shapes become 319 and 144. One block
  // was ADDED and no shape was: the timeout path now emits the failure form
  // `{type, id, spans, failed}` that the error path already emitted, so the vocabulary is
  // unchanged and only the number of sites producing it moved. Nothing gained, lost, or renamed
  // a field.
  //
  // Re-audited 2026-08-14 for the memory page narrative. Same scanner on BOTH revisions: 319 blocks
  // and 144 distinct shapes become 323 and 146. The two additions are `{type, id, summary}` and its
  // failure form `{type, id, summary, failed}`, emitted from one bounded lane that runs only when
  // the app asks for a page's prose. Nothing gained, lost, or renamed a field.
  //
  // Classified `intentionally-omitted`, and worth stating why it is not a new kind of content on
  // this wire. The summary is DERIVED and never authoritative: retrieval quotes claims and never
  // this, so if the prose and a claim disagree the claim wins and the prose is rebuilt — the same
  // relationship `projections.db` has to `library.db`. It is also the one place in this feature
  // where a model writes a sentence not tied to a verbatim quote, which is safe only because of
  // that. The REQUEST carries a page title and the claims the user has already ACCEPTED — never a
  // suggestion, never a conversation, never the assistant's words.
  //
  // Re-audited 2026-08-14 for the narrative grounding rules. Same scanner on BOTH revisions: 323
  // blocks and 146 distinct shapes before and after, nothing added, removed, or renamed. The change
  // is prompt text plus one new REQUEST field, `rules`, on `memory_summarize`.
  //
  // Worth stating at the pin because that field carries Conversation-derived content INTO the
  // daemon: it is the person's own accepted claims about how writing should be done, so that the
  // page recording "no em-dashes" governs the prose written about them. Accepted claims only, never
  // a suggestion, and no wider than the summary request already was.
  //
  // Re-audited 2026-08-15 for the domain-neutral topic vocabulary. The only change is one string in
  // `MEMORY_TOPICS` and the comment above it: "Product direction" becomes "Projects and work",
  // because the original presumed the reader builds products and this list ships to every user.
  // No `emit` is reached by the edit, so the reviewed capture surface is unchanged.
  //
  // Re-audited 2026-08-15 for the introduction. No `emit` is reached: the change is prompt text
  // plus two REQUEST fields on `memory_summarize`, `name` and `pronoun`.
  //
  // Stated at the pin because of what they are rather than how much they are. Both come from the
  // person answering a question about themselves, both are stored as ordinary claims they can
  // correct, and the pronoun in particular has NO other source anywhere in the system: no provider
  // account carries one, macOS does not, and a name does not imply one. It is sent so that prose
  // about a person can use their own words for themselves, and it defaults to "they", which is a
  // correct answer rather than a placeholder.
  //
  // Re-audited 2026-08-15 for the memory wiki editor, which within the same day went from a
  // one-shot line grammar to a real turn with tools. Only the final shape is pinned. Same
  // character-level brace/string scanner applied to both revisions: 281 blocks and 129 distinct
  // shapes become 287 and 132. Three additions, no removals, and no existing block gained, lost or
  // renamed a field:
  //
  //   `{type, id, reqId, operation, args}` — the daemon asking the APP to carry out one memory tool
  //     call, because `library.db` is the app's authority under a single-writer lease and nothing in
  //     the daemon may touch it. Answered by a `memory_op_response` request in the other direction.
  //   `{type, id, reply}` and its failure form `{type, id, reply, failed}` — the terminal result of
  //     one wiki-editing turn.
  //
  // `memory_chat_delta` is `{type, id, text}`, which is the existing conversation `delta` shape, so
  // it adds no distinct shape. It is streamed prose from a model, the same class of content the
  // conversation delta already carries.
  //
  // All of it is classified `intentionally-omitted` alongside the other memory lanes: control
  // traffic about the person's own wiki, not Conversation content.
  //
  // What the REQUEST carries is worth stating. `memory_chat` sends the person's instruction and the
  // earlier turns of that panel, and NOT the wiki — the assistant reads that through tools, so only
  // the pages it actually asks for are ever rendered into a request. `args` carries tool arguments:
  // page titles, statement numbers, and for `Remember` a statement and a citation. The citation is
  // checked in the app against what the person typed in that panel, and the evidence corpus never
  // leaves the app, so a tool argument can never supply the proof of its own claim.
  //
  // Every memory lane now also resolves `req.model` through `memoryModel()` rather than a hardcoded
  // id, adding one optional REQUEST field, `model`, to the memory request types. Never the
  // conversation's model, which is why it is a separate field rather than a reuse of the turn's.
  //
  // Re-audited 2026-08-15 for memory recall. One addition to the vocabulary,
  // `{type, id, reqId, query}`: the daemon asking the APP what it remembers that is relevant to a
  // turn. The answer comes back as a `memory_recall_response` request in the other direction and is
  // not an emit at all.
  //
  // What the request carries is the whole point of its shape: a query string, and nothing else. The
  // daemon never decides what may be disclosed. Scope is a property of the person's own library and
  // its rules live beside the rows — a `private` claim is never sent to any provider, and a
  // workspace claim never leaves its workspace — so the app derives WHICH workspace and WHICH lane
  // from the connection the request arrived on rather than trusting either to be reported. There is
  // a test that the request body contains no scope, workspace or privacy vocabulary at all.
  //
  // Classified `intentionally-omitted` with the other memory lanes: control traffic about the
  // person's own library rather than Conversation content. What is DISCLOSED is recorded in the
  // transcript as an existing `memoryRecall` entry, which is a product surface and not a new event.
  //
  // Re-scanned in the same revision for the Claude-side recall guidance. No emit is reached: the
  // change adds one system-prompt append naming the tool, which shipped documented to Codex and
  // undocumented to Claude. Same delta as above.
  //
  // Re-audited 2026-08-15 for stopping a wiki turn. Checked emit by emit. One INBOUND request type,
  // `{type, id}` as `memory_chat_stop`, which carries nothing but the id of the turn to abort and
  // reaches no emit of its own. And one optional field on the existing terminal result:
  // `{type, id, reply, stopped}` beside the `failed` form already recorded above. Both are the same
  // class as everything else in this lane and stay `intentionally-omitted` — control traffic about
  // the person's own wiki rather than Conversation content.
  //
  // Worth stating because it is the reason the field exists: an abort throws, so without `stopped`
  // a turn the person stopped would arrive as `failed: true` and be shown to them as a provider
  // that could not be reached. That is the "could not" versus "nothing" collapse this feature has
  // already shipped three times, and the extra field is what keeps the two apart on the wire.
  // Re-audited 2026-08-15 for learning from an ordinary conversation. One addition to the
  // vocabulary, and it is the first memory emit that carries CONTENT rather than only control:
  // `{type, id, reqId, statement, quote, topic}` — the daemon offering the app something worth
  // remembering, with the words it believes establish it.
  //
  // Worth being exact about what `quote` is, because "the person's own words" appears twice in this
  // feature and means different things. What travels here is the MODEL'S rendering of a span it
  // believes it saw. The app then locates that rendering in what the person actually typed and
  // stores THEIR characters, never the model's, so nothing the daemon sends becomes evidence by
  // being sent. The conversation itself never leaves the app, and the request carries no messages,
  // no transcript and no history: there is a test asserting exactly that.
  //
  // Answered by a `memory_capture_response` request in the other direction, which is not an emit.
  // Classified `intentionally-omitted` with the rest of the lane: control traffic about the person's
  // own wiki. What is CAPTURED shows up in the transcript as an existing `memoryRecall` entry, which
  // is a product surface and not a new event.
  // Re-audited 2026-08-16 for the page-summary prompt. Wording only: the instruction now asks for
  // prose about the PERSON and forbids opening with "This page", after a rebuilt library produced
  // "This page records that the user is named David Liebke". No emit, no field and no vocabulary
  // changed, so the lane's classification is untouched.
  // Re-audited 2026-08-16 for two life topics. `MEMORY_TOPICS` gains "Family and friends" and
  // "Interests", and the two capture tool descriptions list them. A wiki about a person that can
  // only file what they do for work is a personnel record. Vocabulary the model may put in an
  // existing `topic` field: no emit, no field and no lane classification changed.
  // Re-audited 2026-08-16 for summary length. A page's lead is now proportionate to the page: two
  // paragraphs past twenty statements, four or five sentences past ten, and the old two or three
  // below that. Prompt wording only, on a request that already existed.
  // Re-audited 2026-08-16 for cited prose. The summary prompt now asks for a citation at the end of
  // every sentence, against the numbered statements it was already given, and drops the ban on
  // words the statements do not contain. Prompt wording on an existing request: the reply is still
  // one string on the same `memory_summary_result` emit, and the app parses and verifies it.
  // Re-audited 2026-08-16, twice over. `memory_chat` gains an `openPage` field: the title of the
  // page the person is looking at, so "rewrite this page" refers to something. A page title, from
  // the app to the daemon, on a request that already carries the instruction and the conversation.
  // And `WriteSummary`'s description now asks for a citation on every sentence, matching the
  // backfill. No emit changed and the lane stays intentionally-omitted control traffic.
  // Re-audited 2026-08-16 for the missing capture case. `memory_capture_response` is a request the
  // APP already sent and the daemon had no case for, so `completeMemoryCapture` — which existed —
  // was never reached. Adding the dispatch entry introduces no emit and no field: it lets an
  // existing round trip finish instead of timing out and surfacing an error in the transcript.
  // Re-audited 2026-08-16 for the capture collision. `RememberThis` is narrowed to what the person
  // EXPLICITLY asks to be remembered, because the app now reads every message for durable facts on
  // its own and both paths were writing: one sentence became three claims in 29 seconds. Tool
  // description only. No emit, no field, no lane change.
  // Re-audited 2026-08-16 for project documentation. `memory_select` messages may now carry
  // `describes`: the workspace a document is about, sent by the app so the selector can be asked
  // what the THING is rather than what the person prefers. Without it the prompt forbade taking a
  // fact from documentation and eighteen files were read, sent and correctly ignored. One optional
  // string on an existing request; the reply shape is unchanged and no emit moved.
  // Re-audited 2026-08-17. `memory_summarize` may now carry `subject`: the name of the THING a page
  // is about, when the page is a workspace rather than one of the closed topics about the person.
  // Without it the writer was told unconditionally to write about THE PERSON with their name and
  // pronoun, so a page built from facts about a project opened with a sentence about its owner —
  // a summary of the memories rather than of the project. One optional string on an existing
  // request; the reply shape is unchanged, no emitted field added or removed, and every
  // classification count in the audit above is unchanged.
  // Re-audited 2026-08-18 for `MergeStatements`, the wiki agent's tool for combining several
  // wordings of one fact into the one that survives. The whole change is inside
  // `buildMemoryToolServer` and `runMemoryChat`: one `operation()` declaration, its entry in the
  // tool-name list, and three lines of prompt guidance saying to reach for it instead of
  // `ForgetStatement`, because forgetting a repeat asserts the fact is wrong and stops it being
  // learned again. Checked mechanically as usual: 333 `emit({…})` blocks before and after, and the
  // diff does not touch a single line containing `emit` — so nothing gained, lost, or renamed a
  // field. Merging is a memory-store mutation and reaches the transcript through the wiki agent's
  // existing reply, not through a new event.
  // Re-audited 2026-08-18 for the restricted Memory-workspace editor and public-source research.
  // A character-level call scanner finds 333 `emit({…})` blocks before and 334 after. Two duplicate
  // timeout sites using the existing memory-selector and summary failure shapes were consolidated;
  // three sites were added: the existing `{type, id, message}` `control_error` shape plus success
  // and failure forms of `memory_research_result`. The success form carries the app-approved
  // `{title, kind}` subject and at most eight `{fact, excerpt, sourceURL}` proposals, with the exact
  // hosted-web URLs repeated in `sources`; the failure form carries empty candidate/source arrays,
  // `failed`, and a bounded error discriminator. This is intentionally-omitted app/daemon control
  // traffic, not Conversation content: the app revalidates the subject and route, then records each
  // surviving item as a sourced review proposal rather than an accepted memory. The remaining
  // changes select a bounded provider tool surface and correlate existing memory request/response
  // control traffic; no existing event field, type, or value source was added, removed, or renamed.
  // Re-audited 2026-08-20 for the subagent memory channel. The same character-level scan finds
  // 334 `emit({…})` blocks before and 334 after, and no changed line contains `emit` at all. The
  // change is three things, none of which is captured wire content: one field read off the inbound
  // `send` control request onto `ctx` (app to daemon, never emitted back), one optional parameter on
  // `buildToolServers`, and a conditional clause appended to the `RecallMemory` tool DESCRIPTION,
  // which is provider request text rather than a Conversation field. No event or outbound request
  // gained, lost, or renamed anything.
  // Re-audited 2026-08-20 for subagent attribution on the memory lanes. 334 `emit({…})` blocks
  // before and after; TWO emits changed, both gaining the same optional field. `memory_recall_request`
  // and `memory_capture_request` each carry `by` — the name of the subagent that made the call, when
  // exactly one was running — so a memory read or written inside a delegated task is as visible as
  // one the parent made. It is a name from the task lifecycle the daemon already watches, never
  // anything from the person's library, and it is absent when no subagent is live.
  //
  // Classification unchanged, on the precedent recorded above for this whole lane: these are
  // control traffic about the person's own wiki rather than Conversation content, and what is
  // disclosed shows up in the transcript as an existing `memoryRecall` entry. That entry gains an
  // optional `memoryRecallSubagent`, which is a product surface on an existing record kind rather
  // than a new event, and optional so an older transcript decodes unchanged.
  // Re-audited 2026-08-20 for the page-summary bound. 334 `emit({…})` blocks before and after; ONE
  // changed line, and it changes a VALUE rather than a field: `memory_summary_result.summary` is
  // still one string on the same event. It was `text.trim().slice(0, 1200)`, a flat cap that cut a
  // 117-statement page mid-word and contradicted the prompt directly above it, which already asks
  // for two paragraphs on a page that size. It is now bounded by the page and cut at the citation
  // that ends a sentence. No event or outbound request gained, lost, or renamed anything.
  // Re-audited 2026-08-21 for the SUBAGENT MEMORY ATTACHMENT. Same character-level brace/string
  // scanner on BOTH revisions: 292 `emit({…})` blocks and 100 distinct top-level shapes before and
  // after, with the shape SETS diffed rather than only counted — zero added, zero removed.
  //
  // Nothing here is a new event. The changes are a `PreToolUse` hook registered on `Task`, a
  // non-emitting helper that rewrites the subagent's brief, a third parameter on
  // `requestMemoryRecall`, and prompt text. The one emit involved — `memory_recall_request` — keeps
  // `{type, id, reqId, query}` plus its existing optional `by`; what changed is WHO computes `by`,
  // so that a recall made on behalf of a subagent that has not started yet is attributed to it
  // instead of to the main agent. Same field, same optionality, truer value.
  // Re-audited 2026-08-21, second pass, for making the same hook name-proof. No emit changed: the
  // edits are a `Set` of accepted tool names, a guard reading `tool_name`, and one `log()` line,
  // which writes to the daemon's own log rather than to the wire.
  // Re-audited 2026-08-21 for executable subagent-memory delivery on both provider lanes. There are
  // 334 `emit({…})` blocks before and after, and no changed line contains `emit`. Claude now retains
  // the inbound response's `empty` bit in an internal promise result so an empty recall does not
  // rewrite a child brief. Codex accepts a dynamic-tool request only after its provider-authored
  // child thread has been joined to an active root turn, then passes the known child path leaf into
  // the existing optional `by` field on `memory_recall_request` and `memory_capture_request`. Same
  // request shapes and optionality as the prior audit; only the attribution value is made precise.
  // The obsolete
  // inbound `memorySubjects` catalog is now ignored instead of being copied into Claude's tool
  // description; removing that internal request read also leaves the daemon's outbound wire intact.
  // Re-audited 2026-08-21 for the bounded summary trust boundary and subject forwarding. There are
  // 334 `emit({…})` blocks before and after, and no changed line contains `emit`. The existing
  // inbound `memory_summarize.subject` field now reaches the existing summary function instead of
  // being dropped at dispatch; the remaining edits turn the same request fields into one delimited
  // JSON data block and change provider prompt text. No emitted or outbound-request field, shape,
  // optionality, or value source changed, so the reviewed capture vocabulary remains identical.
  // The same pass also corrects one existing MergeStatements tool-description string to match the
  // UI; that provider prompt copy likewise reaches no `emit` or outbound request.
  // Re-audited 2026-08-21 after the live MultiAgentV2 acceptance test proved that App Server rejects
  // direct `turn/steer` input to spawned children. A tool-capable Codex child now calls the existing
  // RecallMemory dynamic tool under inherited developer guidance. If no call arrives, the bounded
  // fallback asks through the existing `memory_recall_request`, then uses App Server's supported
  // `thread/inject_items` method. That request now has optional `suppressDisclosure` plus required
  // internal `disclosureKind`; together they distinguish a silent history selection, an automatic
  // Claude selection, and an explicit tool recall without changing the wiki content returned to a
  // provider. One new turn-scoped, content-free `memory_recall_ack` event carries only
  // `{type,id,reqId,disclosureKind}`. It proves the matching provider-result boundary before Swift
  // publishes the existing transcript card; silent fallback emits no acknowledgement. Both are
  // transient app-daemon coordination, not persisted capture vocabulary or provider/user content,
  // so the canonical capture field inventory remains unchanged.
  // Re-audited again after the stored-memory injection review. The only subsequent agentd source
  // change adds developer prompt text telling the isolated Memory editor to treat titles,
  // summaries, claims, statements and excerpts returned by its tools as untrusted wiki data. It
  // also makes Codex's fallback attempted/explicit state generation-wide so a better task signal
  // cannot repeat delivery, while a new provider `sendInput` still starts one new generation.
  // Neither edit changes an `emit` call, outbound request field, captured value source, or
  // persisted shape.
  // Re-audited 2026-08-21 for the provider-supported Codex MultiAgentV2 memory-tool seam. Ordinary
  // Codex threads now receive a transient, authenticated loopback MCP config whose two calls route
  // into the existing `memory_recall_request`, `memory_capture_request`, and content-free
  // `memory_recall_ack` coordination events described above. The added owner waiters, provider
  // `mcpToolCall` completion check, proxy bypass, and daemon-lifetime bridge state are all transient;
  // no `emit` call, emitted field, captured value source, or persisted capture shape changed. The
  // random server name and bearer remain outside both the conversation record and this field oracle.
  // Re-audited 2026-08-21 for provider-native MultiAgentV2 follow-up turns. A distinct
  // provider-owned child turn ID now reopens only the existing in-memory child ownership and its
  // memory generation; a replayed terminal turn ID remains rejected. The edit changes no `emit`
  // call, emitted field, captured value source, or persisted capture shape.
  // Re-audited 2026-08-21 for the Codex child-memory readiness gate. The 30-second generation timer,
  // child-scoped `mcpServerStatus/list` tool proof, exact transient bridge/process identity checks,
  // and fail-open history decision remain daemon-local coordination. Scheduling the retained task
  // signal for a provider-native follow-up likewise changes no `emit` call, emitted field, captured
  // value source, or persisted capture shape.
  // Re-audited 2026-08-22 after teaching the existing memory span-selection prompt to prioritize
  // durable user corrections and emphasized rules. This changes only instructions for the same
  // bounded selector response; it adds no `emit` call, emitted field, captured value source, or
  // persisted capture shape.
  // Re-audited 2026-08-23 for the first typed verified-build receipt. The agent-facing Build
  // result now carries one optional `verifiedKnowledgeObservation` object plus its correlation
  // id, and the transient Build-tab `build_result` event carries the same optional observation.
  // The observation is content-free: closed lifecycle/effect/command values, timestamps, exit and
  // error counts, opaque correlation identity, and one-way workspace/invocation/diagnostic hashes.
  // It contains no build output, diagnostic prose, workspace path, prompt, statement, or provider
  // response. Build runner events are outside the nine reviewed format-capture fixtures and the
  // provider-neutral workflow_update surface above, so this deliberately does not widen the
  // canonical capture inventory. Swift separately validates the exact app-owned Build route before
  // persisting the canonical receipt on its transcript authority row.
  // Re-audited 2026-08-23 for fresh verified-build workspace recapture. One app-to-daemon request
  // adds one fixed result event with {type,id,command,status,reason,snapshot}; the snapshot has only
  // rootSHA256, headCommit, dirtyTreeSHA256, and toolchainSHA256. Request identifiers are UUIDs,
  // commands and reasons are closed values, errors and paths are never echoed, and the existing
  // bounded capture helper runs only read-only Git queries plus the selected build tool's version
  // query. This transient control-plane result is neither provider/user content nor a persisted
  // Conversation capture event, so it deliberately does not widen the canonical capture inventory.
  // Re-audited 2026-08-24 for Claude's supported PostCompact summary handoff. `agentd.mjs` adds one
  // `compaction_summary` emit carrying the helper's exact shape and adds `compactionSequence` to
  // `compact_boundary`; both are classified above. The helper is pinned independently because its
  // inline-versus-temp-file branches define the event's complete union. The root-C adapter has no
  // summary-refinement mapping yet, so no new field is classified canonical. The same agentd
  // revision moves `openAIHistory` to its runtime module and adjusts fresh-context prompt/steering
  // plus PostCompact replay-safety control flow; none of those changes adds another emit shape.
  // Re-audited 2026-08-24 for source-backed agent-memory provenance. The complete diff changes
  // only the Claude/OpenAI memory descriptions, untrusted-memory guidance, the memory-editor prompt, and
  // one delegated-task prompt; no `emit` call, emitted field, captured value source, or persisted
  // capture shape changed.
  // Re-audited 2026-08-24 for background Vertex credential rejection. `ready` gains the optional
  // `accountFailure` used by the native lane/account recovery surface. It is the existing bounded,
  // provider-neutral credential-failure shape: closed kind/provider/access values, fixed product
  // copy, a bounded allowlisted provider code/status, and a reconnect boolean. Google response
  // prose, identity, token material, prompts, and conversation ids never enter it. The field is
  // absent from all nine reviewed fixtures, like optional `accountStatus`/`accountInstanceId`, and
  // is transient account control state rather than a canonical turn-record fact; fixture-observed
  // capture vocabulary and dispositions therefore remain unchanged.
  // Re-audited 2026-08-25 for Vertex credential rejection ordering. The existing turn terminal is
  // now emitted before the existing disconnected-ready and empty-catalog publications; no event
  // type, field, provider content, or capture vocabulary changes.
  // Re-audited 2026-08-25 for Codex dynamic-tool ownership. Child tool_use and tool_result events
  // now populate the existing optional `parentToolUseId` with the authoritative child thread id;
  // root calls still omit it. That field is already classified canonical for both event types and
  // no event type, field name, provider content, or fixture-observed vocabulary is added.
  // Re-audited 2026-08-25 for signed Mechanician Help retrieval. The daemon adds two transient
  // control-plane shapes: `help_search_request` carries {type,id,reqId,query} plus optional
  // includeHistory, and `help_search_ack` carries only {type,id,reqId}. The request is routed to
  // the app-owned signed corpus and never persisted as provider/user content; the content-free
  // acknowledgement merely proves the provider result was written before the app persists its
  // own concise consultation receipt. Existing emitted fields and the canonical capture vocabulary
  // are unchanged, so both new events are deliberately omitted from this turn-record prototype.
  // The follow-up unattended guard only filters provider tool schemas and fails a stale call before
  // bridge transport; it adds no emit shape or value source.
  // Re-audited 2026-08-25 for the closed Help expert profile. Profile selection remains transient
  // app-to-daemon configuration and is never emitted or persisted by this capture path. Claude,
  // OpenAI, and Codex expose only the already reviewed SearchMechanicianHelp transport; its request
  // and acknowledgement retain the exact shapes above. Closed-profile refusals use existing
  // control_error/tool_result fields, and the neutral cwd, deny-root permission name, disabled MCP
  // table, developer guidance, and provider configuration are not turn-record capture events. No
  // emitted field, captured value source, or canonical capture disposition changes.
  // Re-audited 2026-08-25 for the closed Codex profile boundary. Tool profiles now participate in
  // the opaque thread-session and warm-thread proofs, Review stamps the standard profile, the
  // private Memory MCP repeats that authorization at dispatch, and an ownerless elicitation is
  // declined before the UI. These are provider/control-plane checks only: they add no emitted
  // field, captured value source, or canonical capture disposition.
  // Re-audited 2026-08-25 for exact-turn capability evidence. The daemon adds one bounded
  // `tool_surface` shape carrying {type,id,lane,toolProfile,permissionMode,coverage,provenance,
  // adapterRevision,tools}. Claude derives names from that turn's accepted SDK init, OpenAI from
  // the exact accepted Responses request, and Codex from the exact accepted thread configuration.
  // This transient app presentation/advice evidence is not written to a Conversation transcript
  // or canonical capture, and it cannot authorize an invocation. It is therefore omitted from the
  // reviewed capture vocabulary just like legacy `tool_catalog`. The new helper is pinned beside
  // the producer because it owns the complete shape and byte/name/count bounds.
  // Re-audited 2026-08-25 for signed workflow advice. The daemon adds bounded transient
  // `workflow_advice_request` and `workflow_advice_ack` events containing only root turn id,
  // request id, and (on the request) the user's bounded goal plus an optional validated signed
  // demonstration id. The app response is stdin-only;
  // route identity, raw tool surfaces, readiness calculations, and signed recipes never enter the
  // daemon event stream. The app persists only the existing concise Help consultation receipt
  // after acknowledgement, so these transport events add no canonical capture field or value
  // source and are deliberately omitted from this prototype's reviewed vocabulary.
  // Re-audited 2026-08-27 for signed in-app Help presentation. The daemon adds two bounded,
  // transient control-plane shapes: `show_mechanician_request` carries exactly
  // {type,id,reqId,guideID}, while `show_mechanician_ack` carries {type,id,reqId}. `guideID` is a
  // shape-bounded candidate handle admitted only by the app's signed authority, not provider
  // content to persist; the app response is stdin-only and succeeds only with the closed `started`
  // state. Presentation completion,
  // coordinates, selectors, scripts, URLs, window/workspace ids, and UI content never enter the
  // daemon event stream. The provider-facing call still uses the already reviewed tool_use and
  // tool_result shapes, and the expanded tool_surface only adds a value inside its existing
  // transient `tools` array. Interrupt now settles app-authority promises immediately but adds no
  // event or field. These presentation events therefore add no canonical capture field or value
  // source and are deliberately omitted from this prototype's reviewed vocabulary.
  // Re-audited 2026-08-27 for the Codex account-refresh lease. `account/read` now sends
  // `refreshToken` only when this daemon claimed the shared CODEX_HOME lease, so a single-use
  // ChatGPT grant is rotated once per home rather than once per daemon. The request is provider
  // control traffic that is never captured, and the account and model_catalog events it leads to
  // are unchanged in type, field set, provider content, and fixture-observed capture vocabulary.
  // Re-audited 2026-08-29 for OperateMechanician. `operate_mechanician_request` and its
  // response are app-authority round trips of the same class as the presentation events
  // above: they carry one operation name and one optional short target, are never persisted
  // to a transcript, and add no canonical capture field or value source. The provider-facing
  // call still uses the reviewed tool_use and tool_result shapes, and the tool_surface event
  // only gains one more value inside its existing transient `tools` array.
  // Re-audited 2026-08-29 for the confirmed operations. `enableExtension` and
  // `disableExtension` reuse the existing operate request/response pair and only suppress
  // its client-side deadline so the round trip can wait for a person; no event, field, or
  // captured value changes.
  // Re-audited again 2026-08-29 for the bypass-availability pairing: that change sets one SDK
  // launch option and emits nothing, so it adds no capture field and no value source either.
  // This hash covers BOTH audits, recomputed from the merged file rather than taken from
  // either side, because each side's hash describes a file that no longer exists.
  // Re-audited 2026-08-31 for harness observability. `harness_observation` carries a turn id plus
  // closed lane/event/provenance/scope/aggregation values, bounded counts and timings, coarse
  // outcomes, bounded model identifiers, and closed tool categories. It never carries prompt or
  // response text, tool input or output, paths, command lines, provider error prose, or account
  // identity. Swift may persist these observations as AgentActivity, but root C has no kind-aware
  // mapping for this new family; the existing `agentActivity` sidecar rule therefore remains
  // `not-yet-captured`. The fixture-derived capture vocabulary is not widened to imply parity that
  // the adapter lacks.
  //
  // `harness_metrics` is a lane-level aggregate batch with no stable Mechanician turn id, and
  // `harness_account_usage` is an account-level Codex snapshot with no turn id. Both are runtime
  // UI state and are never written to Conversation authority, so neither is a portable turn-record
  // fact. The separately pinned OTLP helper admits only allowlisted metric families and attributes;
  // the account normalizer strips bucket ids, balances, and provider display labels before its
  // snapshot reaches the wire.
  //
  // Existing `usage` events gain `provenance`, `scope`, and `aggregation`; Claude usage also gains
  // `providerQuerySequence` so retries can be reconciled without double counting. The Claude-only
  // `inputUncached`, `cacheWrite`, `cacheRead`, and `agentToolUseId` fields already predated this
  // change. Root C currently maps only the fixture-reviewed input/cached/output/reasoning totals,
  // so these optional production enrichments remain outside this fixture-derived wire inventory;
  // when persisted, their structured copies stay under the explicit `agentActivity` gap above.
  //
  // Codex child `workflow_update` gains `toolEventID`, a bounded provider item handle used only to
  // merge that visible workflow boundary with its parallel harness tool outcome and duration. The
  // deterministic workflow fixture now exercises the field, and the exact disposition above is
  // intentionally omitted until root C has a tool-observation refinement to remint and retain.
  // Claude child `workflow_update` also carries the positive `providerQuerySequence` into its
  // usage activity so an agent-tree final suppresses only same-query snapshots. That ordinal is
  // separately, intentionally omitted until root C maps query-scoped usage refinements.
  // The remaining changes start and stop a private loopback metrics receiver and add phase, retry,
  // compaction, model, tool, context, result, rate-limit, and token-usage observations using those
  // reviewed helper shapes; they add no other field to the curated capture surface.
  // Re-audited 2026-09-01 for the write-containment and commit-scoping fixes. Neither adds a
  // capture field or a value source.
  //
  // `makeWriteContainmentHook` runs `credentialStoreReadDenial` and `escapingWriteTarget` from a
  // PreToolUse hook, because the SDK does not invoke `canUseTool` under `bypassPermissions` and
  // both checks were consequently running in no Full-access turn. It emits only the existing
  // `permission_request` (with its existing `writeEscape` object) and the existing subtraction
  // event, both already in this inventory. Its refusal travels in the SDK's own hook-output shape
  // and is never persisted; `preToolUseDenial`/`pendingPermissionDenial` moved to
  // `interaction-closure.mjs`, which this contract does not pin.
  //
  // `git_commit` gains a pre-flight comparison of the real index against the caller's declared
  // `expectedPaths` and, on a mismatch, emits the existing `git_done` with `ok: false` and a
  // message. `expectedPaths` is a request field on a provider-neutral control, not a captured
  // event field, and no `git_*` result event gains a key.
  // Re-audited 2026-09-01 for delegated lifecycle ownership. Claude Agent/Task routes now survive
  // resumed SDK queries and keep existing child model/tool/usage and `workflow_update` events on
  // the launching turn. Codex duplicate and mixed Interacted/sendInput representations now open
  // exactly one lifecycle generation. Session/account/provider retirement uses the existing
  // `workflow_update` stopped status. No event type, field name, value source, or capture
  // disposition changes; the changes are routing, replay suppression, and lifecycle reduction.
  // Re-audited 2026-09-01 for Claude's catalog-resolved alias identity. The optional
  // `catalogResolvedModel` is app-to-daemon request metadata retained only on the live turn and
  // warm-query identity; it is not emitted or persisted. Context-window logs and the existing
  // `context_windows` control-plane snapshot can now use the concrete model id behind a stable
  // wire alias, but that snapshot remains outside Conversation capture and keeps its existing
  // {type, windows} shape. Inspection of every changed hunk found no added, removed, or renamed
  // `emit` field and no captured value source or disposition change.
  // Re-audited 2026-09-02 for repository evidence on the provider-neutral `git_status` control.
  // Its new request selectors and `git_status_result.repositoryEvidence` / `fullCommit` reply
  // fields are one-shot Git control data: they carry the echoed control request id, never a turn
  // id, and do not enter the Conversation event-capture surface reviewed by this contract. No
  // provider turn event, captured value source, or existing capture disposition changed. The
  // per-candidate `targetRelationship` and verified activity-file `digest` are likewise one-shot
  // Git results derived only from immutable Git object IDs and exact file bytes; the internal Git
  // exit code is not emitted.
  // Re-audited 2026-09-04 for Codex imageGeneration transcript media. Its completed App Server
  // item now emits the existing tool_use/tool_result pair plus a private-local random temporary
  // handoff path and exact byte count. Swift consumes that path before routing, deletes it, and
  // persists only the existing conversation-owned `toolImage` reference; provider paths and image
  // bytes never enter the portable capture. The reviewed tool_result vocabulary therefore gains
  // exactly generatedImagePath/generatedImageBytes, both private-local.
  // Re-audited 2026-09-02 for managed enterprise policy enforcement. Provider allowlisting,
  // permission clamping, extension-source filtering, connector/plugin suppression, and unattended
  // dispatch refusal are ingress/tool-availability decisions. A Plan ceiling reuses the existing
  // `subtraction` shape and `plan_mode_readonly` reason. A disabled WaitFor now returns through the
  // existing provider tool-error path before permission authorization and deliberately emits no
  // `waiting` event. A managed turn whose effective mode is Plan (including Plan selected below a
  // wider administrative ceiling) removes OperateMechanician from the existing exact tool surface
  // and rejects forged or stale calls before the existing app-operation request bridge. The boot
  // ceiling remains a defense in depth. Managed MCP declarations now also reject built-in server
  // names and use own-property checks during their tool-map merge; this changes neither wire events
  // nor provider observations. No event field, captured value source, or capture disposition
  // changes.
  // Re-audited 2026-09-07 for Claude background-task lifetime. The daemon now consumes the SDK's
  // private control-plane `background_tasks_changed` level only to delay closing its provider input
  // while user-visible work remains live. It emits no new event and changes no existing event field,
  // captured value source, or capture disposition.
  // Re-audited 2026-09-09 after a comment-only provenance wording change. No event field,
  // captured value source, or capture disposition changes.
  'agentd/src/agentd.mjs': 'a683f4f06aa5df87c43f501c1f9630da1a82e1c5f3b61ec0bf2f9ef6b1bdfe94',
  'agentd/src/harness-observations.mjs': '67237f2d6926f8985e57adb02d63d659f0f1a574ad91420223cdee93a7ba1135',
  'agentd/src/otel-metrics-receiver.mjs': '2b5655e5f5c84dedfd3c4e21a76a66d7c21202b6f18ddf74a2ab380eb399b30c',
  'agentd/src/tool-surface.mjs': 'bb46bbd990d90e81ec28de1e9af29c2afd59d0c4083a4abf8a92dae739c52673',
  'agentd/src/claude-compaction-summary.mjs': '70b89ef098fd04b0265b69dc40f45bfcc97b745d553562df267cec63f5b1df31',
  'agentd/src/claude-message-events.mjs': '82678329ca3c4334e103b91a25e678c92a726c7622e79205551e51d4ee855384',
  'agentd/src/codex-workflows.mjs': '9844c61230d15b7d8ff1d4b0adc4acbb29390fc7c3d0c5caa54e1ab6af721fb8',
  'agentd/test/fixtures/format-review-lifecycle-fixture.mjs': 'bb154808eae11b1bb52ef6d5ddad605a9f1a0e357b3c889d17c0172a2acce00a',
  'agentd/test/fixtures/format-review-interaction-lifecycle-fixture.mjs': '2784c023ed2cb462e4730f03b240212dc0385b0bd7f551469da1db864a7c7698',
  'agentd/test/fixtures/activity-agents-compaction-fixture.mjs': '625db1e84b5d5460ebf59bbae1a5107e036e6189c21ac8ba76db815c26d6ebb6',
  'agentd/test/fixtures/claude-usage-limit-delegates-fixture.mjs': '8b107729c57ce2b1b8239b465ddd9b23975d3a6d553c6a663bbdfc5fd315a992',
  'agentd/test/fixtures/parallel-agents-fixture.mjs': 'c2d7726c85efbf47b4f1b1ed9d15900c0c98ec813dc66e6f9fcea4d2d4cbaa80',
  'agentd/test/fixtures/steering-busy-fixture.mjs': 'a74038988015a8dc37b52a7e210637193655cfa392eee6ba5fedfdc5451dfc08',
  'agentd/test/fixtures/nested-delegation-fixture.mjs': '7619166454fe8760b7ba9973e7956e6bcb677837385b40a1a461d9a7f0800467',
  'agentd/test/fixtures/minimal-conversation-fixture.mjs': 'eb53acc2e13844fd1cc0236016ac7d642f2c13e60bebb8fd8652e72513fbb35a',
  'agentd/test/fixtures/format-review-workflow-lifecycle-fixture.mjs': 'eb2f8026f3f1d2ef165e00f5f7c8ce374240f559a6c1409fe08aad34df8c46e1',
}

// These reviewed paths are absent from the ordinary successful-capture baseline. The deterministic
// format-review lifecycle fixture now exercises the error, steering, interruption, result-preview and
// post-root-terminal variants with an explicit completion condition; model catalog remains a
// separate discovery variant. Subtracting this set therefore measures only baseline reachability,
// not total reviewed-fixture coverage.
export const REVIEWED_CAPTURE_PRODUCTION_SOURCE_FIELDS = [
  'isWorkflowRun', 'workflowName', 'agentPath', 'parentToolUseId',
  'toolEvent', 'toolTarget', 'toolEventID', 'providerQuerySequence',
  'usage.toolUses', 'usage.durationMs', 'usage.toolUsesObserved',
  'usage.reasoningOutputTokens', 'outputFile',
  'workflowProgress', 'workflowProgress[]', 'workflowProgress[].type',
  'workflowProgress[].index', 'workflowProgress[].title', 'workflowProgress[].phaseIndex',
  'workflowProgress[].label', 'workflowProgress[].phaseTitle', 'workflowProgress[].state',
  'workflowProgress[].agentId', 'workflowProgress[].model', 'workflowProgress[].attempt',
  'workflowProgress[].lastToolName', 'workflowProgress[].lastToolSummary',
  'workflowProgress[].promptPreview', 'workflowProgress[].tokens',
  'workflowProgress[].toolCalls', 'workflowProgress[].resultPreview',
  'workflowProgress[].error', 'workflowProgress[].durationMs',
]

export function reviewedCaptureFieldKey({ eventType = null, outboundType = null, path }) {
  if (eventType && outboundType) throw new Error('a reviewed capture field cannot be both inbound and outbound')
  const scope = eventType
    ? `event:${eventType}`
    : outboundType ? `outbound:${outboundType}` : 'envelope'
  return `${scope}:${path}`
}

export const REVIEWED_CAPTURE_BASELINE_EXCLUSIONS = new Set([
  ...REVIEWED_CAPTURE_ENVELOPE_FIELDS
    .filter((field) => field.startsWith('outboundRequests') || field.startsWith('quiescence'))
    .map((path) => reviewedCaptureFieldKey({ path })),
  ...Object.entries(REVIEWED_CAPTURE_OUTBOUND_REQUEST_FIELDS).flatMap(
    ([outboundType, fields]) => fields.map((field) => reviewedCaptureFieldKey({
      outboundType, path: `outboundRequests[].request.${field}`,
    }))),
  reviewedCaptureFieldKey({ eventType: 'model_catalog', path: 'events[].event.id' }),
  reviewedCaptureFieldKey({
    eventType: 'workflow_update', path: 'events[].event.resultPreview',
  }),
  ...['type', 'id', 'errorKind', 'rateLimitType', 'resetsAt', 'message']
    .map((field) => reviewedCaptureFieldKey({
      eventType: 'error', path: `events[].event.${field}`,
    })),
  ...['type', 'id', 'status', 'rateLimitType', 'limitLabel', 'utilization',
    'surpassedThreshold', 'resetsAt', 'isUsingOverage']
    .map((field) => reviewedCaptureFieldKey({
      eventType: 'usage_status', path: `events[].event.${field}`,
    })),
  ...['type', 'id', 'turnId', 'steerId']
    .map((field) => reviewedCaptureFieldKey({
      eventType: 'steer_ack', path: `events[].event.${field}`,
    })),
  ...['type', 'id', 'turnId', 'steerId']
    .map((field) => reviewedCaptureFieldKey({
      eventType: 'steer_rejected', path: `events[].event.${field}`,
    })),
  reviewedCaptureFieldKey({ eventType: 'done', path: 'events[].event.interrupted' }),
  ...['permission_request', 'permission_response_ack', 'question_request',
    'question_response_ack', 'interaction_closed'].flatMap((eventType) =>
    REVIEWED_CAPTURE_EVENT_FIELDS[eventType].map((field) => reviewedCaptureFieldKey({
      eventType, path: `events[].event.${field}`,
    }))),
  reviewedCaptureFieldKey({ eventType: 'tool_result', path: 'events[].event.isError' }),
  ...['generatedImagePath', 'generatedImageBytes'].map((field) => reviewedCaptureFieldKey({
    eventType: 'tool_result', path: `events[].event.${field}`,
  })),
  reviewedCaptureFieldKey({ eventType: 'tool_use', path: 'events[].event.frameUUID' }),
  // The deterministic compaction fixture predates the provider correlation sequence, and no
  // checked-in fixture invokes Claude's PostCompact hook. Keep production-only review from being
  // mistaken for baseline reachability.
  reviewedCaptureFieldKey({
    eventType: 'compact_boundary', path: 'events[].event.compactionSequence',
  }),
  ...REVIEWED_CAPTURE_EVENT_FIELDS.compaction_summary.map((field) => reviewedCaptureFieldKey({
    eventType: 'compaction_summary', path: `events[].event.${field}`,
  })),
  // A recall is emitted only when the provider's memory supervisor surfaces something, which no
  // deterministic fixture does. Its normalization is covered directly by
  // agentd/test/claude-memory-recall.test.mjs rather than by baseline reachability.
  ...REVIEWED_CAPTURE_EVENT_FIELDS.memory_recall.map((field) => reviewedCaptureFieldKey({
    eventType: 'memory_recall', path: `events[].event.${field}`,
  })),
  // Emitted only in response to an explicit app request, which no capture fixture makes.
  ...REVIEWED_CAPTURE_EVENT_FIELDS.memory_extract_result.map((field) => reviewedCaptureFieldKey({
    eventType: 'memory_extract_result', path: `events[].event.${field}`,
  })),
  ...REVIEWED_CAPTURE_PRODUCTION_SOURCE_FIELDS.map(
    (field) => reviewedCaptureFieldKey({
      eventType: 'workflow_update', path: `events[].event.${field}`,
    })),
])

export function auditReviewedCaptureSurface() {
  const classified = []
  const unclassified = []
  for (const path of REVIEWED_CAPTURE_ENVELOPE_FIELDS) {
    const result = classifyReviewedCaptureField(path)
    if (result) classified.push({ eventType: null, outboundType: null, ...result })
    else unclassified.push({ eventType: null, outboundType: null, path })
  }
  for (const [eventType, fields] of Object.entries(REVIEWED_CAPTURE_EVENT_FIELDS)) {
    for (const field of fields) {
      const path = `events[].event.${field}`
      const result = classifyReviewedCaptureField(path, eventType)
      if (result) classified.push({ eventType, outboundType: null, ...result })
      else unclassified.push({ eventType, outboundType: null, path })
    }
  }
  for (const [outboundType, fields] of Object.entries(
    REVIEWED_CAPTURE_OUTBOUND_REQUEST_FIELDS)) {
    for (const field of fields) {
      const path = `outboundRequests[].request.${field}`
      const result = classifyReviewedCaptureField(path, null, outboundType)
      if (result) classified.push({ eventType: null, outboundType, ...result })
      else unclassified.push({ eventType: null, outboundType, path })
    }
  }
  return { classified, unclassified }
}

// Compatibility aliases for the dated evidence script. New work and reports use the reviewed
// capture-surface terminology; the parent slice will migrate the evidence JSON without coupling
// this fail-closed oracle change to unrelated files.
export const GENERATOR_CAPTURE_FIELDS = REVIEWED_CAPTURE_ENVELOPE_FIELDS
export const GENERATOR_OBSERVED_FIELDS = REVIEWED_CAPTURE_EVENT_FIELDS
export const GENERATOR_SOURCE_PINS = REVIEWED_CAPTURE_SOURCE_PINS
export const GENERATOR_NORMAL_CAPTURE_EXCLUSIONS = REVIEWED_CAPTURE_BASELINE_EXCLUSIONS
export const classifyGeneratorField = classifyReviewedCaptureField
export const auditGeneratorInventory = auditReviewedCaptureSurface

export const CANONICAL_NORMALIZATIONS = [{
  name: 'agent-registry-order',
  reason: 'agent registry order carries no history; identities and parentage do',
}, {
  name: 'assistant-delta-coalescing',
  reason: 'adjacent streamed deltas become one retained assistant message without changing text order',
}]

export function normalizeCanonical(canonical) {
  const normalized = clone(canonical)
  normalized.agents = [...(normalized.agents ?? [])].sort((a, b) => String(a.id).localeCompare(String(b.id)))
  return normalized
}

function stableJSON(value) {
  assertJSONValue(value)
  if (value === null || typeof value !== 'object') return JSON.stringify(value)
  if (Array.isArray(value)) return `[${value.map(stableJSON).join(',')}]`
  return `{${Object.keys(value).sort().map((key) => `${JSON.stringify(key)}:${stableJSON(value[key])}`).join(',')}}`
}

export function canonicalDigest(canonical) {
  return crypto.createHash('sha256').update(stableJSON(normalizeCanonical(canonical))).digest('hex')
}

function leafMap(value) {
  const leaves = new Map()
  const visit = (node, path) => {
    if (Array.isArray(node)) {
      if (node.length === 0) leaves.set(path, '[]')
      else node.forEach((item, index) => visit(item, `${path}[${index}]`))
      return
    }
    if (node && typeof node === 'object') {
      const entries = Object.entries(node)
      if (entries.length === 0) leaves.set(path, '{}')
      else entries.forEach(([key, child]) => visit(child, path ? `${path}.${key}` : key))
      return
    }
    leaves.set(path, JSON.stringify(node))
  }
  visit(value, '')
  return leaves
}

export function compareCanonicalFields(original, decoded) {
  const before = leafMap(normalizeCanonical(original))
  const after = leafMap(normalizeCanonical(decoded))
  const paths = [...new Set([...before.keys(), ...after.keys()])].sort()
  return paths.filter((path) => before.get(path) !== after.get(path)).map((path) => ({
    path,
    original: before.get(path),
    decoded: after.get(path),
  }))
}

export const EXTERNAL_ROOT_LOSS_RULES = [
  { pattern: /^agents\[\d+\]\.task$/, code: 'prototype-decoder-omits-agent-task' },
  { pattern: /^events\[\d+\]\.observedAt$/, code: 'prototype-decoder-omits-timestamp' },
  { pattern: /^events\[\d+\]\.timeProvenance$/, code: 'prototype-encoding-omits-time-provenance' },
  { pattern: /^events\[\d+\]\.recipientProvenance$/, code: 'prototype-encoding-omits-recipient-provenance' },
  { pattern: /^events\[\d+\]\.sessionIdentityProvenance$/, code: 'prototype-encoding-omits-session-identity-provenance' },
  { pattern: /^events\[\d+\]\.summary$/, code: 'prototype-decoder-omits-agent-message-summary' },
  { pattern: /^events\[\d+\]\.input(?:\.|$)/, code: 'prototype-decoder-omits-tool-input' },
  { pattern: /^events\[\d+\]\.status$/, code: 'prototype-encoding-omits-tool-result-status' },
]

export function classifyFieldDifferences(differences, rules = EXTERNAL_ROOT_LOSS_RULES) {
  const declaredLosses = []
  const unclassified = []
  for (const difference of differences) {
    const rule = rules.find((candidate) => candidate.pattern.test(difference.path))
    if (rule) declaredLosses.push({ ...difference, code: rule.code })
    else unclassified.push(difference)
  }
  return { declaredLosses, unclassified }
}

export function authoritativeLeafPaths(canonical) {
  return [...leafMap(normalizeCanonical(canonical)).keys()].sort()
}
