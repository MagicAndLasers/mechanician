// Sidecar -> canonical graph: the adapter that lets the R2 harness run over the REAL-shape
// sanitized corpus (and the seed of R3's legacy-JSON adapter). Deliberate decisions, recorded:
// - persisted agentActivity state/identity/token/context rows are the event source for agent facts.
//   Tool rows are normally UI projections of transcript-owned facts and are excluded, except for
//   exact workflow-agent identities: a workflow child's tools do not otherwise occur in the root
//   transcript, so those rows are its canonical observations. Compaction/interjection rows remain
//   transcript-owned projections.
// - tool rows become a tool_call + tool_result pair sharing the row's toolUseId. A result-less row
//   that the app reconciled to stopped retains that local terminal fact without claiming the
//   provider reported cancellation.
// - subagents are mutable metadata summaries, not an event history. Exact activity identity + phase
//   rows establish spawn/result boundaries and are enriched from the summary. A summary without a
//   matching ordinal-bearing activity boundary is retained only as explicitly degraded legacy fact.
// - workflow runs, phases, and agents are graph structure plus mutable latest-state summaries. Exact
//   `workflow:<run-key>:<agent-key>` activity identities own child lifecycle, usage, and tool history;
//   summary-only lifecycle is one explicitly degraded snapshot, never a second spawn/result history.
// - settled permission/question cards become inert historical interactions with fresh record-local
//   ids. A durable user selection survives independently from acknowledgement; an explicit closure
//   settles an unanswered request without fabricating a deny/answer. Only truly live pending cards
//   (no selection, acknowledgement, or closure) remain operative private state and are omitted.
// - compaction rows become first-class compaction events — the fact BOTH candidate drafts
//   cannot express natively.
// - capture ordinals, when complete, order accepted provider-callback batches. Facts sharing one
//   ordinal are intentionally unordered: a stable local event id supplies canonical serialization,
//   never fabricated causality. Legacy or partially upgraded sidecars keep deterministic adapter
//   traversal order and carry a degraded diagnostic; wall clocks never silently become an order.
// The adapter's dated R2 callers retain their historical graph marker. Product bindings wrap the
// resulting graph with their own explicit format marker rather than silently rewriting old evidence.
export const CANONICAL_FORMAT = 'mechanician-canonical-graph/0-spike'

function terminalOutcome(status) {
  switch (status) {
    case 'completed':
    case 'done':
    case 'success':
    case 'succeeded': return 'succeeded'
    case 'error':
    case 'failed': return 'failed'
    case 'cancelled':
    case 'interrupted':
    case 'killed':
    case 'stopped': return 'stopped'
    default: return 'unknown'
  }
}

export function canonicalFromSidecar(sidecar) {
  const agents = [{ id: 'root', parentId: null, type: 'root', task: null }]
  const workflows = []
  const workflowPhases = []
  const captured = []
  let missingCaptureOrdinals = 0
  let invalidCaptureOrdinals = 0
  let missingStableEventIds = 0
  let legacySummaryEventCount = 0
  let degradedWorkflowSummaryEventCount = 0
  let traversalIndex = 0

  const append = (event, rawCaptureOrdinal) => {
    const supplied = rawCaptureOrdinal !== undefined && rawCaptureOrdinal !== null
    const captureOrdinal = Number.isSafeInteger(rawCaptureOrdinal) && rawCaptureOrdinal > 0
      ? rawCaptureOrdinal
      : null
    if (captureOrdinal === null) {
      if (supplied) invalidCaptureOrdinals += 1
      else missingCaptureOrdinals += 1
    } else {
      event.captureOrdinal = captureOrdinal
    }
    const eventId = typeof event.eventId === 'string' && event.eventId.length > 0
      ? event.eventId
      : null
    if (eventId === null) {
      missingStableEventIds += 1
      delete event.eventId
    }
    captured.push({ event, eventId, captureOrdinal, traversalIndex: traversalIndex += 1 })
  }

  const subagentDescriptors = []
  const subagentByActivityIdentity = new Map()
  const activityIdentity = (rawID) => `subagent:${rawID}`
  const registerSubagentIdentity = (rawID, descriptor) => {
    if (typeof rawID !== 'string' || rawID.length === 0) return
    const identity = activityIdentity(rawID)
    const existing = subagentByActivityIdentity.get(identity)
    if (existing && existing !== descriptor) {
      throw new Error(`ambiguous persisted subagent activity identity: ${identity}`)
    }
    subagentByActivityIdentity.set(identity, descriptor)
  }

  for (const [storageKey, sub] of Object.entries(sidecar.subagents ?? {})) {
    const subagentId = typeof sub.key === 'string' && sub.key.length > 0 ? sub.key : storageKey
    const descriptor = {
      storageKey,
      sub,
      subagentId,
      canonicalId: null,
      delegateCallId: null,
      parentId: 'root',
      spawnActivity: null,
      terminalActivity: null,
    }
    subagentDescriptors.push(descriptor)
    registerSubagentIdentity(storageKey, descriptor)
    registerSubagentIdentity(sub.key, descriptor)
    registerSubagentIdentity(sub.taskId, descriptor)
  }

  // A workflow dictionary is a mutable latest-state projection. Its stable contribution is graph
  // structure and descriptive metadata; exact agentActivity identities own ordered child history.
  // Raw run/agent/provider aliases never leave these correlation maps.
  const workflowDescriptors = []
  const workflowAgentByActivityIdentity = new Map()
  const workflowDelegateKeys = new Set()
  let workflowCounter = 0
  let workflowPhaseCounter = 0
  let workflowAgentCounter = 0
  const registerWorkflowIdentity = (runKey, agentKey, descriptor) => {
    if (typeof runKey !== 'string' || runKey.length === 0
        || typeof agentKey !== 'string' || agentKey.length === 0) return
    const identity = `workflow:${runKey}:${agentKey}`
    const existing = workflowAgentByActivityIdentity.get(identity)
    if (existing && existing !== descriptor) {
      throw new Error(`ambiguous persisted workflow activity identity: ${identity}`)
    }
    workflowAgentByActivityIdentity.set(identity, descriptor)
  }
  for (const [storageKey, run] of Object.entries(sidecar.workflowRuns ?? {})) {
    const workflowId = `workflow-${workflowCounter += 1}`
    const rawRunKeys = [...new Set([storageKey, run.runKey]
      .filter((value) => typeof value === 'string' && value.length > 0))]
    for (const rawKey of [storageKey, run.runKey, run.toolUseId, run.runTaskId]) {
      if (typeof rawKey === 'string' && rawKey.length > 0) workflowDelegateKeys.add(rawKey)
    }
    workflows.push({
      id: workflowId, ownerAgentId: 'root', name: run.workflowName ?? null,
      type: 'workflow', providerConfirmed: true,
      description: run.description ?? '', summary: run.summary ?? null,
      identityProvenance: 'record-local-remint-from-persisted-workflow',
      parentageProvenance: 'persisted-workflow-owned-by-root',
      metadataProvenance: 'persisted-mutable-workflow-summary-enrichment',
    })

    const phases = new Map()
    const ensurePhase = (index, title) => {
      const normalizedIndex = Number.isSafeInteger(index) ? index : null
      const key = normalizedIndex === null ? `unindexed:${title ?? ''}` : `index:${normalizedIndex}`
      let phase = phases.get(key)
      if (!phase) {
        phase = {
          canonicalId: `workflow-phase-${workflowPhaseCounter += 1}`,
          index: normalizedIndex,
          title: typeof title === 'string' ? title : '',
        }
        phases.set(key, phase)
        workflowPhases.push({
          id: phase.canonicalId, workflowId, sourceOrdinal: phase.index, title: phase.title,
          identityProvenance: 'record-local-remint-from-persisted-workflow-phase',
        })
      } else if (!phase.title && typeof title === 'string' && title.length > 0) {
        phase.title = title
        const node = workflowPhases.find((candidate) => candidate.id === phase.canonicalId)
        node.title = title
      }
      return phase
    }
    for (const phase of Object.values(run.phases ?? {})) {
      ensurePhase(phase.index, phase.title)
    }
    const agentEntries = Object.entries(run.agents ?? {}).sort((left, right) => {
      const phaseDelta = (left[1].phaseIndex ?? 0) - (right[1].phaseIndex ?? 0)
      if (phaseDelta !== 0) return phaseDelta
      return (left[1].index ?? 0) - (right[1].index ?? 0)
    })
    for (const [agentKey, agent] of agentEntries) {
      const phase = ensurePhase(agent.phaseIndex, agent.phaseTitle)
      const descriptor = {
        run, agent, workflowId, phaseId: phase.canonicalId,
        canonicalId: `workflow-agent-${workflowAgentCounter += 1}`,
        exactStateActivities: [],
      }
      workflowDescriptors.push(descriptor)
      for (const rawRunKey of rawRunKeys) {
        registerWorkflowIdentity(rawRunKey, agentKey, descriptor)
      }
      agents.push({
        id: descriptor.canonicalId, parentId: 'root', type: 'workflow-agent',
        task: agent.promptPreview ?? '', workflowId, phaseId: descriptor.phaseId,
        label: agent.label ?? null, sourceOrdinal: agent.index ?? null,
        attempt: agent.attempt ?? null, observedModel: agent.model ?? null,
        identityProvenance: 'record-local-remint-from-exact-persisted-workflow-alias',
        parentageProvenance: 'workflow-owner',
        metadataProvenance: 'persisted-mutable-workflow-summary-enrichment',
      })
    }
  }
  const retainedActivityKinds = new Set([
    'state', 'identity', 'tokens', 'context', 'tool', 'compaction', 'interjection',
  ])
  const hasCaptureOrdinal = (activity) =>
    Number.isSafeInteger(activity.captureOrdinal) && activity.captureOrdinal > 0
  const orderedActivitiesForIdentity = (sidecar.agentActivity ?? [])
    .map((activity, index) => ({ activity, index }))
    .filter(({ activity }) => retainedActivityKinds.has(activity.kind)
      || (activity.kind === 'tool' && workflowAgentByActivityIdentity.has(activity.agentID)))
    .sort((left, right) => {
      const leftCaptured = hasCaptureOrdinal(left.activity)
      const rightCaptured = hasCaptureOrdinal(right.activity)
      if (leftCaptured !== rightCaptured) return leftCaptured ? -1 : 1
      if (leftCaptured && left.activity.captureOrdinal !== right.activity.captureOrdinal) {
        return left.activity.captureOrdinal - right.activity.captureOrdinal
      }
      const leftID = typeof left.activity.id === 'string' ? left.activity.id : ''
      const rightID = typeof right.activity.id === 'string' ? right.activity.id : ''
      if (leftID !== rightID) return leftID < rightID ? -1 : 1
      return left.index - right.index
    })

  // Raw provider aliases remain confined to these exact-match maps. Portable actor and delegate-call
  // ids are minted from retained capture order; rows without ordinals fall back to deterministic
  // array/map traversal and necessarily keep the conversion's chronology degraded.
  const allocatedActors = []
  const activityActorByRawIdentity = new Map()
  let actorCounter = 0
  const allocateDescriptor = (descriptor) => {
    if (descriptor.canonicalId !== null) return
    descriptor.canonicalId = `agent-${actorCounter += 1}`
    allocatedActors.push({ descriptor, canonicalId: descriptor.canonicalId })
  }
  const allocateActivityActor = (rawIdentity, activity) => {
    if (activityActorByRawIdentity.has(rawIdentity)) return
    const actor = { rawIdentity, activity, canonicalId: `agent-${actorCounter += 1}` }
    activityActorByRawIdentity.set(rawIdentity, actor)
    allocatedActors.push(actor)
  }
  for (const { activity } of orderedActivitiesForIdentity) {
    const rawIdentity = typeof activity.agentID === 'string' && activity.agentID.length > 0
      ? activity.agentID
      : 'root'
    if (rawIdentity === 'root') continue
    const descriptor = subagentByActivityIdentity.get(rawIdentity)
    if (descriptor) allocateDescriptor(descriptor)
    else if (workflowAgentByActivityIdentity.has(rawIdentity)) continue
    else allocateActivityActor(rawIdentity, activity)
  }
  // New captures stamp tool ownership on the transcript-owned fact itself so bounded activity
  // trimming cannot erase attribution. Allocate those aliases before graph emission; historical
  // sidecars continue through the exact activity fallback below.
  for (const row of sidecar.messages ?? []) {
    if (row.kind !== 'tool'
        || typeof row.toolOwnerAgentID !== 'string'
        || row.toolOwnerAgentID.length === 0
        || row.toolOwnerAgentID === 'root') continue
    const descriptor = subagentByActivityIdentity.get(row.toolOwnerAgentID)
    if (descriptor) allocateDescriptor(descriptor)
    else if (!workflowAgentByActivityIdentity.has(row.toolOwnerAgentID)) {
      allocateActivityActor(row.toolOwnerAgentID, row)
    }
  }
  for (const descriptor of subagentDescriptors) allocateDescriptor(descriptor)

  let delegateCallCounter = 0
  for (const actor of allocatedActors) {
    if (actor.descriptor) {
      actor.descriptor.delegateCallId = `delegate-call-${delegateCallCounter += 1}`
    }
  }

  for (const actor of allocatedActors) {
    if (actor.descriptor) {
      const descriptor = actor.descriptor
      const { sub, canonicalId } = descriptor
      let parentageProvenance = 'persisted-no-parent-reference'
      if (typeof sub.parentToolUseId === 'string' && sub.parentToolUseId.length > 0) {
        const observedParent = activityIdentity(sub.parentToolUseId)
        const parent = subagentByActivityIdentity.get(observedParent)
        descriptor.parentId = parent?.canonicalId ?? null
        parentageProvenance = parent
          ? 'exact-persisted-parent-alias'
          : 'unavailable-unresolved-parent-alias'
      }
      agents.push({
        id: canonicalId,
        parentId: descriptor.parentId,
        type: sub.subagentType ?? 'agent',
        task: sub.task ?? '',
        identityProvenance: 'record-local-remint-from-exact-persisted-alias',
        parentageProvenance,
      })
    } else {
      agents.push({
        id: actor.canonicalId,
        parentId: null,
        type: actor.activity.agentLabel ?? 'agent',
        task: null,
        identityProvenance: 'record-local-remint-from-persisted-activity-alias',
        parentageProvenance: 'unavailable',
      })
    }
  }

  const turnIDByRawIdentity = new Map()
  let turnCounter = 0
  for (const { activity } of orderedActivitiesForIdentity) {
    if (typeof activity.turnID !== 'string' || activity.turnID.length === 0) continue
    if (!turnIDByRawIdentity.has(activity.turnID)) {
      turnIDByRawIdentity.set(activity.turnID, `turn-${turnCounter += 1}`)
    }
  }
  for (const row of sidecar.messages ?? []) {
    for (const rawTurnID of [row.toolTurnID, row.compactionTurnID]) {
      if (typeof rawTurnID === 'string' && rawTurnID.length > 0
          && !turnIDByRawIdentity.has(rawTurnID)) {
        turnIDByRawIdentity.set(rawTurnID, `turn-${turnCounter += 1}`)
      }
    }
  }

  const canonicalAgentIDForRawIdentity = (rawIdentity) => {
    if (rawIdentity === 'root') return 'root'
    return subagentByActivityIdentity.get(rawIdentity)?.canonicalId
      ?? workflowAgentByActivityIdentity.get(rawIdentity)?.canonicalId
      ?? activityActorByRawIdentity.get(rawIdentity)?.canonicalId
      ?? null
  }
  const canonicalAgentIDForActivity = (activity) => {
    const rawIdentity = typeof activity.agentID === 'string' && activity.agentID.length > 0
      ? activity.agentID
      : 'root'
    return canonicalAgentIDForRawIdentity(rawIdentity)
  }

  // Transcript tool/user/compaction rows own the content; AgentActivity owns actor, turn, delivery,
  // and failure metadata that the transcript shape does not carry. Correlate by the one shared
  // durable order plus kind-specific identity/content evidence, keeping exactly one enriched event.
  const toolActivityByMessage = new Map()
  const compactionActivityByMessage = new Map()
  const interjectionActivityByMessage = new Map()
  const matchedActivities = new Set()
  const usedMessages = new Set()
  const exactCaptureMessage = (activity, accepts) => {
    if (!(Number.isSafeInteger(activity.captureOrdinal) && activity.captureOrdinal > 0)) return null
    const candidates = (sidecar.messages ?? []).filter((row) =>
      !usedMessages.has(row)
        && Number.isSafeInteger(row.captureOrdinal) && row.captureOrdinal > 0
        && row.captureOrdinal === activity.captureOrdinal
        && accepts(row))
    return candidates.length === 1 ? candidates[0] : null
  }
  const correlate = (activity, target, accepts) => {
    const row = exactCaptureMessage(activity, accepts)
    if (!row) return
    usedMessages.add(row)
    matchedActivities.add(activity)
    target.set(row, activity)
  }
  const activityRows = [...(sidecar.agentActivity ?? [])].sort((left, right) =>
    (left.captureOrdinal ?? Number.MAX_SAFE_INTEGER)
      - (right.captureOrdinal ?? Number.MAX_SAFE_INTEGER))
  for (const activity of activityRows) {
    switch (activity.kind) {
      case 'tool':
        correlate(activity, toolActivityByMessage, (row) =>
          row.kind === 'tool'
            && typeof row.toolName === 'string'
            && typeof activity.detail === 'string'
            && row.toolName.trim() === activity.detail.trim())
        break
      case 'compaction':
        correlate(activity, compactionActivityByMessage, (row) =>
          row.kind === 'compaction'
            && (activity.compactionTrigger == null || row.compactionTrigger == null
              || activity.compactionTrigger === row.compactionTrigger)
            && (activity.compactionPreTokens == null || row.compactionPreTokens == null
              || activity.compactionPreTokens === row.compactionPreTokens)
            && (activity.compactionPostTokens == null || row.compactionPostTokens == null
              || activity.compactionPostTokens === row.compactionPostTokens)
            && (activity.compactionError == null || row.compactionError == null
              || activity.compactionError === row.compactionError))
        break
      case 'interjection':
        correlate(activity, interjectionActivityByMessage, (row) =>
          row.kind === 'user'
            && (activity.detail == null
              || String(row.text ?? '').slice(0, 240) === activity.detail))
        break
      default:
        break
    }
  }

  // Only an ordinal-bearing state observation can establish a non-legacy lifecycle boundary. The
  // summary's boundary ordinal is an explicit correlation pointer, not an ordering source; identity
  // joins are exact (`subagent:<key-or-taskId>`). Timestamps and labels never correlate.
  const boundaryCandidates = new Map(subagentDescriptors.map((descriptor) => [descriptor, []]))
  for (const activity of sidecar.agentActivity ?? []) {
    const descriptor = subagentByActivityIdentity.get(activity.agentID)
    if (!descriptor || activity.kind !== 'state') continue
    if (!(Number.isSafeInteger(activity.captureOrdinal) && activity.captureOrdinal > 0)) continue
    if (!(typeof activity.id === 'string' && activity.id.length > 0)) continue
    boundaryCandidates.get(descriptor).push(activity)
  }
  const terminalActivityPhases = new Set(['completed', 'failed', 'stopped'])
  const exactBoundary = (descriptor, rows, ordinal, accepts, boundaryName) => {
    if (!(Number.isSafeInteger(ordinal) && ordinal > 0)) return null
    const matches = rows.filter((row) => row.captureOrdinal === ordinal && accepts(row))
    if (matches.length > 1) {
      throw new Error(
        `ambiguous persisted ${boundaryName} activity for ${descriptor.canonicalId} at ${ordinal}`)
    }
    return matches[0] ?? null
  }
  for (const descriptor of subagentDescriptors) {
    const rows = boundaryCandidates.get(descriptor)
    descriptor.spawnActivity = exactBoundary(
      descriptor,
      rows,
      descriptor.sub.startedCaptureOrdinal,
      (row) => typeof row.phase === 'string' && !terminalActivityPhases.has(row.phase),
      'spawn')
    descriptor.terminalActivity = exactBoundary(
      descriptor,
      rows,
      descriptor.sub.endedCaptureOrdinal,
      (row) => terminalActivityPhases.has(row.phase),
      'terminal')
  }

  for (const activity of sidecar.agentActivity ?? []) {
    const descriptor = workflowAgentByActivityIdentity.get(activity.agentID)
    if (descriptor && activity.kind === 'state') descriptor.exactStateActivities.push(activity)
  }
  const workflowPhaseFromState = (state) => {
    switch (state) {
      case 'queued': return 'waiting'
      case 'start':
      case 'progress': return 'model'
      case 'done': return 'completed'
      case 'failed': return 'failed'
      case 'stopped': return 'stopped'
      default: return null
    }
  }
  const workflowUsageSummary = (agent) => {
    const usage = {
      totalTokens: agent.tokens ?? null,
      toolUses: agent.toolCalls ?? null,
      durationMs: agent.durationMs ?? null,
    }
    return Object.values(usage).some((value) => value !== null) ? usage : null
  }

  // Old sidecars often predate workflow-owned activity rows. Preserve one latest-state snapshot for
  // such an agent, but label it as degraded and never synthesize a spawn/result pair from the same
  // mutable dictionary. Exact state rows suppress this fallback completely.
  for (const descriptor of workflowDescriptors) {
    if (descriptor.exactStateActivities.length > 0) continue
    const { agent, canonicalId, workflowId, phaseId } = descriptor
    degradedWorkflowSummaryEventCount += 1
    legacySummaryEventCount += 1
    const outcome = agent.state == null ? null : terminalOutcome(agent.state)
    append({
      kind: 'agent_lifecycle', eventId: `workflow-summary:${canonicalId}:state`,
      agentId: canonicalId, workflowId, phaseId,
      phase: workflowPhaseFromState(agent.state), state: agent.state ?? null,
      outcome: ['done', 'failed', 'stopped'].includes(agent.state) ? outcome : null,
      description: agent.promptPreview ?? null,
      summary: agent.lastToolSummary ?? null, lastToolName: agent.lastToolName ?? null,
      resultPreview: agent.resultPreview ?? null, observedModel: agent.model ?? null,
      usage: workflowUsageSummary(agent), error: agent.error ?? null,
      attempt: agent.attempt ?? null, durationMs: agent.durationMs ?? null,
      stateProvenance: 'degraded-workflow-summary-without-event-ledger-match',
      summaryProvenance: 'persisted-mutable-workflow-summary',
      chronologyProvenance: 'degraded-legacy-summary',
      observedAt: agent.endedAt ?? agent.startedAt ?? null,
      timeProvenance: agent.endedAt || agent.startedAt ? 'persisted-observation' : 'unknown',
    }, null)
  }

  // Summary-derived boundaries are retained solely for old/incomplete sidecars. Even when a summary
  // happens to carry an ordinal, it is mutable latest-state data and therefore forces degraded
  // chronology instead of competing with the append-only activity ledger.
  for (const descriptor of subagentDescriptors) {
    const { sub, canonicalId, parentId, delegateCallId } = descriptor
    if (!descriptor.spawnActivity) {
      legacySummaryEventCount += 1
      append({
        kind: 'agent_spawn', eventId: `legacy-summary:${canonicalId}:spawn`,
        agentId: parentId, spawnedAgentId: canonicalId, toolUseId: delegateCallId,
        agentType: sub.subagentType ?? 'agent', task: sub.task ?? '',
        spawnProvenance: 'degraded-legacy-subagent-summary',
        chronologyProvenance: 'degraded-legacy-summary',
        observedAt: sub.startedAt ?? null, timeProvenance: 'persisted-observation',
      }, sub.startedCaptureOrdinal)
    }
    if (sub.status && sub.status !== 'running' && !descriptor.terminalActivity) {
      legacySummaryEventCount += 1
      const outcome = terminalOutcome(sub.status)
      append({
        kind: 'agent_call_result', eventId: `legacy-summary:${canonicalId}:result`,
        agentId: parentId, completedAgentId: canonicalId, toolUseId: delegateCallId,
        result: sub.resultPreview ?? '', status: sub.status, outcome,
        isError: outcome === 'failed', stateProvenance: 'degraded-legacy-subagent-summary',
        chronologyProvenance: 'degraded-legacy-summary',
        observedAt: sub.endedAt ?? null, timeProvenance: 'persisted-observation',
      }, sub.endedCaptureOrdinal)
    }
  }

  const activityCommon = (activity, agentID) => ({
    eventId: typeof activity.id === 'string' && activity.id.length > 0
      ? `activity:${activity.id}`
      : null,
    agentId: agentID,
    turnId: turnIDByRawIdentity.get(activity.turnID) ?? null,
    agentLabel: activity.agentLabel ?? null,
    providerAccess: activity.providerAccess ?? null,
    observedModel: activity.modelID ?? null,
    activityProvenance: 'persisted-agent-activity',
    observedAt: activity.at ?? null,
    timeProvenance: activity.at ? 'persisted-observation' : 'unknown',
  })

  for (const activity of sidecar.agentActivity ?? []) {
    const workflowDescriptor = workflowAgentByActivityIdentity.get(activity.agentID)
    const descriptor = subagentByActivityIdentity.get(activity.agentID)
    const agentID = canonicalAgentIDForActivity(activity)
    if (agentID == null) continue
    const common = activityCommon(activity, agentID)
    switch (activity.kind) {
      case 'state': {
        if (workflowDescriptor) {
          const summary = workflowDescriptor.agent
          const isLatestState = workflowDescriptor.exactStateActivities.at(-1) === activity
          append({
            ...common,
            kind: 'agent_lifecycle',
            workflowId: workflowDescriptor.workflowId, phaseId: workflowDescriptor.phaseId,
            phase: activity.phase ?? null, state: activity.phase ?? null,
            outcome: terminalActivityPhases.has(activity.phase)
              ? terminalOutcome(activity.phase)
              : null,
            summary: activity.detail ?? (isLatestState ? summary.lastToolSummary ?? null : null),
            ...(isLatestState ? {
              description: summary.promptPreview ?? null,
              lastToolName: summary.lastToolName ?? null,
              resultPreview: summary.resultPreview ?? null,
              observedModel: activity.modelID ?? summary.model ?? null,
              usage: workflowUsageSummary(summary), error: summary.error ?? null,
              attempt: summary.attempt ?? null, durationMs: summary.durationMs ?? null,
              summaryProvenance: 'persisted-mutable-workflow-summary-enrichment',
            } : {}),
            stateProvenance: 'persisted-agent-activity-state',
          }, activity.captureOrdinal)
        } else if (descriptor?.spawnActivity === activity) {
          append({
            ...common,
            kind: 'agent_spawn', agentId: descriptor.parentId,
            spawnedAgentId: descriptor.canonicalId, toolUseId: descriptor.delegateCallId,
            agentType: descriptor.sub.subagentType ?? activity.agentLabel ?? 'agent',
            task: descriptor.sub.task ?? '', phase: activity.phase ?? null,
            spawnProvenance: 'persisted-agent-activity-state',
          }, activity.captureOrdinal)
        } else if (descriptor?.terminalActivity === activity) {
          const outcome = terminalOutcome(activity.phase)
          append({
            ...common,
            kind: 'agent_call_result', agentId: descriptor.parentId,
            completedAgentId: descriptor.canonicalId, toolUseId: descriptor.delegateCallId,
            result: descriptor.sub.resultPreview ?? descriptor.sub.error ?? '',
            status: activity.phase, outcome, isError: activity.phase === 'failed',
            stateProvenance: 'persisted-agent-activity-state',
          }, activity.captureOrdinal)
        } else {
          append({
            ...common,
            kind: 'agent_lifecycle', phase: activity.phase ?? null,
            state: activity.phase ?? null,
            outcome: terminalActivityPhases.has(activity.phase)
              ? terminalOutcome(activity.phase)
              : null,
            summary: activity.detail ?? null,
            stateProvenance: 'persisted-agent-activity-state',
          }, activity.captureOrdinal)
        }
        break
      }
      case 'identity':
        append({
          ...common,
          kind: 'agent_identity', identityProvenance: 'persisted-agent-activity',
        }, activity.captureOrdinal)
        break
      case 'tokens':
        append({
          ...common,
          kind: 'usage',
          inputTokens: activity.inputTokens ?? null,
          cachedInputTokens: activity.cachedInputTokens ?? null,
          outputTokens: activity.outputTokens ?? null,
          reasoningOutputTokens: activity.reasoningOutputTokens ?? null,
          totalTokens: activity.totalTokens ?? null,
          ...(workflowDescriptor ? {
            workflowId: workflowDescriptor.workflowId,
            phaseId: workflowDescriptor.phaseId,
            cumulativeTotalTokens: workflowDescriptor.agent.tokens ?? null,
            toolUses: workflowDescriptor.agent.toolCalls ?? null,
            durationMs: workflowDescriptor.agent.durationMs ?? null,
            usageSummaryProvenance: 'persisted-mutable-workflow-summary-enrichment',
          } : {}),
          usageProvenance: 'persisted-agent-activity',
        }, activity.captureOrdinal)
        break
      case 'tool':
        if (matchedActivities.has(activity)) break
        append({
          ...common,
          kind: 'agent_lifecycle',
          ...(workflowDescriptor ? {
            workflowId: workflowDescriptor.workflowId,
            phaseId: workflowDescriptor.phaseId,
          } : {}),
          phase: 'tool', state: null, outcome: null,
          summary: activity.toolTarget ?? activity.detail ?? null,
          lastToolName: activity.detail ?? null, toolTarget: activity.toolTarget ?? null,
          stateProvenance: 'persisted-agent-activity-tool-observation',
        }, activity.captureOrdinal)
        break
      case 'compaction':
        if (matchedActivities.has(activity)) break
        append({
          ...common,
          kind: 'compaction',
          trigger: activity.compactionTrigger ?? 'unknown',
          preTokens: activity.compactionPreTokens ?? null,
          postTokens: activity.compactionPostTokens ?? null,
          error: activity.compactionError ?? null,
          isError: activity.compactionError != null,
          outcome: activity.compactionError == null ? 'succeeded' : 'failed',
          compactionProvenance: 'persisted-agent-activity-without-transcript-row',
        }, activity.captureOrdinal)
        break
      case 'interjection':
        if (matchedActivities.has(activity)) break
        append({
          ...common,
          kind: 'user_delivery',
          agentId: 'user', recipientAgentId: agentID,
          userEventKind: activity.userEventKind ?? 'guidance',
          disposition: activity.interjectionDisposition ?? 'unknown',
          contentStatus: activity.interjectionDisposition === 'queued'
            ? 'omitted-private-queued-content'
            : 'unavailable-unmatched-activity',
          deliveryProvenance: 'persisted-agent-activity-without-transcript-row',
        }, activity.captureOrdinal)
        break
      case 'context':
        if (activity.contextEventKind === 'historyReduction') {
          append({
            ...common,
            kind: 'history_reduction',
            omittedMessages: activity.historyOmittedMessages ?? null,
            shortenedMessages: activity.historyShortenedMessages ?? null,
            reason: activity.historyReductionReason ?? null,
            contextProvenance: 'persisted-agent-activity',
          }, activity.captureOrdinal)
        } else {
          append({
            ...common,
            kind: 'context_usage',
            contextTokens: activity.contextTokens ?? null,
            contextWindow: activity.contextWindow ?? null,
            model: activity.modelID ?? null,
            contextProvenance: 'persisted-agent-activity',
          }, activity.captureOrdinal)
        }
        break
      default:
        break
    }
  }

  const delegateKeys = new Set([
    ...Object.keys(sidecar.subagents ?? {}),
    ...Object.values(sidecar.subagents ?? {}).flatMap((subagent) => [
      subagent.key, subagent.taskId,
    ]).filter((value) => typeof value === 'string' && value.length > 0),
    ...workflowDelegateKeys,
  ])
  let unknownToolActorID = null
  const unknownToolActor = () => {
    if (unknownToolActorID !== null) return unknownToolActorID
    unknownToolActorID = 'unknown-tool-actor'
    agents.push({
      id: unknownToolActorID, parentId: null, type: 'unknown-tool-actor', task: null,
      identityProvenance: 'unavailable-legacy-tool-owner',
      parentageProvenance: 'unavailable',
    })
    return unknownToolActorID
  }
  let authorizationCount = 0
  let questionCount = 0
  const correlatedActivityFields = (activity) => activity == null ? {} : {
    turnId: turnIDByRawIdentity.get(activity.turnID) ?? null,
    agentLabel: activity.agentLabel ?? null,
    providerAccess: activity.providerAccess ?? null,
    observedModel: activity.modelID ?? null,
    activityProvenance: 'exact-persisted-activity-correlation',
  }
  for (const row of sidecar.messages ?? []) {
    const observedAt = row.observedAt ?? null
    const entryEventId = row.id == null ? null : `entry:${row.id}`
    // One canonical copy per fact: a delegate's Task call/result appears BOTH as a message tool
    // row and in the subagent metadata/activity sources. The latter retain identity, parentage, and
    // lifecycle observations, so the message-row duplicate is skipped. The R2 harness caught this
    // as 344 round-trip kind mismatches before this guard existed.
    if (row.kind === 'tool' && row.toolUseId && delegateKeys.has(row.toolUseId)) continue
    switch (row.kind) {
      case 'user': {
        const activity = interjectionActivityByMessage.get(row)
        append({
          kind: 'user_message', eventId: entryEventId, agentId: 'user', text: row.text ?? '',
          ...(activity ? {
            ...correlatedActivityFields(activity),
            recipientAgentId: canonicalAgentIDForActivity(activity) ?? 'root',
            userEventKind: activity.userEventKind ?? 'guidance',
            disposition: activity.interjectionDisposition ?? 'delivered',
            deliveryProvenance: 'exact-transcript-activity-correlation',
          } : {}),
          observedAt, timeProvenance: 'persisted-observation',
        }, row.captureOrdinal)
        break
      }
      case 'assistant':
        append({
          kind: 'assistant_message', eventId: entryEventId, agentId: 'root', text: row.text ?? '',
          observedAt, timeProvenance: 'persisted-observation',
        }, row.captureOrdinal)
        break
      case 'tool': {
        const activity = toolActivityByMessage.get(row)
        const persistedOwner = typeof row.toolOwnerAgentID === 'string'
          ? canonicalAgentIDForRawIdentity(row.toolOwnerAgentID)
          : null
        const exactlyObservedOwner = activity == null
          ? null
          : canonicalAgentIDForActivity(activity)
        const isClosedWorldRoot = agents.length === 1 && agents[0]?.id === 'root'
        const ownerAgentID = persistedOwner ?? exactlyObservedOwner
          ?? (isClosedWorldRoot ? 'root' : unknownToolActor())
        const persistedTurnID = turnIDByRawIdentity.get(row.toolTurnID)
        const lifecycleAttribution = activity != null
          ? correlatedActivityFields(activity)
          : persistedTurnID == null ? {} : { turnId: persistedTurnID }
        const ownership = persistedOwner != null ? {
          ...lifecycleAttribution,
          toolOwnershipProvenance: 'persisted-transcript-tool-owner',
        } : activity != null && exactlyObservedOwner != null ? {
          ...lifecycleAttribution,
          toolTarget: activity.toolTarget ?? null,
          toolOwnershipProvenance: 'exact-transcript-activity-correlation',
        } : {
          ...lifecycleAttribution,
          toolOwnershipProvenance: isClosedWorldRoot
            ? 'legacy-closed-world-root'
            : 'unavailable-legacy-multi-actor-record',
        }
        append({
          kind: 'tool_call', eventId: entryEventId, agentId: ownerAgentID,
          toolUseId: row.toolUseId ?? row.id,
          name: row.toolName ?? 'tool', input: row.text ? { summary: row.text } : null,
          ...ownership,
          observedAt, timeProvenance: 'persisted-observation',
        }, row.captureOrdinal)
        if (row.toolResult !== undefined && row.toolResult !== null) {
          const outcome = row.toolIsError === true ? 'failed' : 'succeeded'
          append({
            kind: 'tool_result', eventId: entryEventId == null ? null : `${entryEventId}:result`,
            agentId: ownerAgentID, toolUseId: row.toolUseId ?? row.id,
            result: row.toolResult, isError: outcome === 'failed', outcome,
            ...lifecycleAttribution,
            stateProvenance: 'persisted-tool-result',
            observedAt, timeProvenance: 'persisted-observation',
          }, row.toolResultCaptureOrdinal)
        } else if (row.toolState === 'stopped') {
          append({
            kind: 'tool_terminal', eventId: entryEventId == null ? null : `${entryEventId}:terminal`,
            agentId: ownerAgentID, toolUseId: row.toolUseId ?? row.id,
            outcome: 'stopped', stateProvenance: 'legacy-local-reconciliation',
            ...lifecycleAttribution,
            providerObserved: false,
            observedAt, timeProvenance: 'persisted-observation',
          }, row.toolTerminalCaptureOrdinal)
        }
        if (row.supersessionEventID != null) {
          append({
            kind: 'supersession', eventId: `supersession:${row.supersessionEventID}`,
            agentId: ownerAgentID, targetEventId: entryEventId,
            replacementEventId: row.supersededByEntryID == null
              ? null
              : `entry:${row.supersededByEntryID}`,
            ...lifecycleAttribution,
            reason: 'provider-retraction', historicalOnly: true,
            observedAt: null, timeProvenance: 'ordered-capture-only',
          }, row.supersessionCaptureOrdinal)
        }
        break
      }
      case 'permission': {
        const responseStatus = row.interactionResponseStatus ?? null
        const hasResponse = row.permDecided === true || responseStatus != null
        const closure = row.interactionClosure ?? null
        // A wholly pending card may still name a live provider control handle. Once the user has
        // selected a response or the provider closes the interaction, its history is portable.
        if (!hasResponse && !closure) break
        const interactionId = `authorization-${authorizationCount += 1}`
        append({
          kind: 'authorization_request', eventId: entryEventId,
          agentId: 'root', recipientAgentId: 'user',
          interactionId, toolName: row.permName ?? 'tool',
          input: null, inputDisclosure: 'omitted-private-operative-input',
          boundaryRequest: null, capability: null, historicalOnly: true,
          observedAt, timeProvenance: 'persisted-observation',
        }, row.captureOrdinal)
        if (hasResponse) {
          append({
            kind: 'authorization_response',
            eventId: entryEventId == null ? null : `${entryEventId}:response`,
            agentId: 'user', recipientAgentId: 'root',
            interactionId, decision: row.permAllowed === true ? 'allow' : 'deny',
            requestedScope: row.permAlways === true
              ? 'persistent'
              : row.permAlways === false ? 'once' : null,
            operativeGrantIncluded: false, historicalOnly: true,
            ...(responseStatus == null ? {} : { responseStatus }),
            observedAt: row.interactionResponseObservedAt ?? null,
            timeProvenance: row.interactionResponseObservedAt
              ? 'persisted-observation'
              : 'unknown',
          }, row.interactionResponseCaptureOrdinal)
        }
        if (row.interactionAcknowledgedAt) {
          append({
            kind: 'authorization_ack',
            eventId: entryEventId == null ? null : `${entryEventId}:ack`,
            agentId: 'root', recipientAgentId: 'user',
            interactionId, responseStatus,
            accepted: ['accepted', 'acknowledgementMismatch'].includes(responseStatus)
              ? true
              : responseStatus === 'rejected' ? false : null,
            decisionMatched: responseStatus === 'acknowledgementMismatch' ? false : null,
            historicalOnly: true,
            observedAt: row.interactionAcknowledgedAt,
            timeProvenance: 'persisted-observation',
          }, row.interactionAcknowledgedCaptureOrdinal)
        }
        if (closure) {
          append({
            kind: 'interaction_closed',
            eventId: entryEventId == null ? null : `${entryEventId}:closed`,
            agentId: 'root', recipientAgentId: 'user',
            interactionId, interactionType: 'authorization',
            outcome: closure.outcome, reason: closure.reason,
            historicalOnly: true,
            observedAt: closure.observedAt ?? null,
            timeProvenance: closure.observedAt ? 'persisted-observation' : 'unknown',
          }, closure.captureOrdinal)
        }
        break
      }
      case 'question': {
        const responseStatus = row.interactionResponseStatus ?? null
        const hasResponse = row.questionDecided === true || responseStatus != null
          || row.questionFreeTextResponse != null
        const closure = row.interactionClosure ?? null
        if (!hasResponse && !closure) break
        const interactionId = `question-${questionCount += 1}`
        append({
          kind: 'question', eventId: entryEventId,
          agentId: 'root', recipientAgentId: 'user', interactionId,
          questions: row.questions == null ? null : structuredClone(row.questions),
          contentStatus: row.questions == null ? 'unavailable' : 'retained',
          historicalOnly: true,
          observedAt, timeProvenance: 'persisted-observation',
        }, row.captureOrdinal)
        if (hasResponse) {
          append({
            kind: 'answer', eventId: entryEventId == null ? null : `${entryEventId}:response`,
            agentId: 'user', recipientAgentId: 'root', interactionId,
            answers: row.questionAnswers == null ? null : structuredClone(row.questionAnswers),
            response: row.questionFreeTextResponse ?? null,
            contentStatus: row.questionAnswers == null && row.questionFreeTextResponse == null
              ? 'unavailable'
              : 'retained',
            historicalOnly: true,
            ...(responseStatus == null ? {} : { responseStatus }),
            observedAt: row.interactionResponseObservedAt ?? null,
            timeProvenance: row.interactionResponseObservedAt
              ? 'persisted-observation'
              : 'unknown',
          }, row.interactionResponseCaptureOrdinal)
        }
        if (row.interactionAcknowledgedAt) {
          append({
            kind: 'answer_ack', eventId: entryEventId == null ? null : `${entryEventId}:ack`,
            agentId: 'root', recipientAgentId: 'user',
            interactionId, responseStatus,
            accepted: responseStatus === 'accepted'
              ? true
              : responseStatus === 'rejected' ? false : null,
            historicalOnly: true,
            observedAt: row.interactionAcknowledgedAt,
            timeProvenance: 'persisted-observation',
          }, row.interactionAcknowledgedCaptureOrdinal)
        }
        if (closure) {
          append({
            kind: 'interaction_closed',
            eventId: entryEventId == null ? null : `${entryEventId}:closed`,
            agentId: 'root', recipientAgentId: 'user',
            interactionId, interactionType: 'question',
            outcome: closure.outcome, reason: closure.reason,
            historicalOnly: true,
            observedAt: closure.observedAt ?? null,
            timeProvenance: closure.observedAt ? 'persisted-observation' : 'unknown',
          }, closure.captureOrdinal)
        }
        break
      }
      case 'compaction': {
        const activity = compactionActivityByMessage.get(row)
        const error = row.compactionError ?? activity?.compactionError ?? null
        const persistedTurnID = turnIDByRawIdentity.get(row.compactionTurnID)
        append({
          kind: 'compaction', eventId: entryEventId,
          agentId: activity == null ? 'root' : canonicalAgentIDForActivity(activity) ?? 'root',
          trigger: row.compactionTrigger ?? activity?.compactionTrigger ?? 'unknown',
          preTokens: row.compactionPreTokens ?? activity?.compactionPreTokens ?? null,
          postTokens: row.compactionPostTokens ?? activity?.compactionPostTokens ?? null,
          error, isError: error != null, outcome: error == null ? 'succeeded' : 'failed',
          ...(activity ? {
            ...correlatedActivityFields(activity),
            compactionProvenance: 'exact-transcript-activity-correlation',
          } : {
            ...(persistedTurnID == null ? {} : { turnId: persistedTurnID }),
            compactionProvenance: 'persisted-transcript-row',
          }),
          observedAt, timeProvenance: 'persisted-observation',
        }, row.captureOrdinal)
        break
      }
      default:
        append({
          kind: 'system', eventId: entryEventId, agentId: 'root', text: row.text ?? '',
          sourceKind: row.kind ?? 'unknown',
          observedAt, timeProvenance: 'persisted-observation',
        }, row.captureOrdinal)
        break
    }
  }
  const validOrdinals = captured
    .map(({ captureOrdinal }) => captureOrdinal)
    .filter((value) => value !== null)
  const ordinalCounts = new Map()
  for (const captureOrdinal of validOrdinals) {
    ordinalCounts.set(captureOrdinal, (ordinalCounts.get(captureOrdinal) ?? 0) + 1)
  }
  const eventIdCounts = new Map()
  for (const { eventId } of captured) {
    if (eventId !== null) eventIdCounts.set(eventId, (eventIdCounts.get(eventId) ?? 0) + 1)
  }
  const duplicateStableEventIds = [...eventIdCounts.values()]
    .reduce((total, count) => total + Math.max(0, count - 1), 0)
  const complete = missingCaptureOrdinals === 0
    && invalidCaptureOrdinals === 0
    && missingStableEventIds === 0
    && duplicateStableEventIds === 0
    && legacySummaryEventCount === 0
  const ordered = complete
    ? [...captured].sort((left, right) =>
        left.captureOrdinal - right.captureOrdinal
          || (left.eventId < right.eventId ? -1 : left.eventId > right.eventId ? 1 : 0))
    : captured
  const chronology = complete
    ? {
        status: 'complete', basis: 'record-local-capture-partial-order',
        tieSemantics: 'same-ordinal-events-are-an-unordered-capture-batch',
        serializationOrder: 'capture-ordinal-then-stable-event-id',
        maximumCaptureOrdinal: validOrdinals.length ? Math.max(...validOrdinals) : null,
        captureBatchCount: ordinalCounts.size,
        eventCount: captured.length,
      }
    : {
        status: 'degraded', basis: 'adapter-traversal-only',
        diagnostic: 'cross-source-order-unavailable',
        eventCount: captured.length,
        capturedOrdinalEventCount: validOrdinals.length,
        missingCaptureOrdinalEventCount: missingCaptureOrdinals,
        invalidCaptureOrdinalEventCount: invalidCaptureOrdinals,
        stableEventIdEventCount: captured.length - missingStableEventIds,
        missingStableEventIdEventCount: missingStableEventIds,
        duplicateStableEventIdEventCount: duplicateStableEventIds,
        legacySummaryEventCount,
        ...(degradedWorkflowSummaryEventCount > 0 ? { degradedWorkflowSummaryEventCount } : {}),
      }
  return {
    format: CANONICAL_FORMAT, sessionIds: [], agents,
    ...(workflows.length > 0 ? { workflows } : {}),
    ...(workflowPhases.length > 0 ? { workflowPhases } : {}),
    chronology,
    events: ordered.map(({ event }) => event),
  }
}
