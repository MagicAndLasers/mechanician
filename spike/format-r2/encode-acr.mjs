// Root B: canonical graph -> one provisional VAC-like record (JSON encoding).
// IMPORTANT: this spike has not passed the pinned VAC CDDL. Its original keys (`entry-id`,
// `role`, `arguments`, `content`) are self-consistent with the decoder below but not the draft's
// `id`, typed user/assistant entries, `input`, and `output`. It is fit-gap evidence only and must
// never be described as conformant. The CDDL gives one `agent-meta` per record and NO per-entry
// agent identity; delegation nesting rides entry parent-id trees; agent-to-agent recipients have
// no home at all. Facts in those holes travel via the CDDL's `* tstr => any` extensibility as
// `x-agent-id` / `x-recipient-agent-id` members — classified `extension` (legal, but a foreign
// reader has no registry telling it what they mean) — and the record stays honest by listing
// what a non-extension reader loses.
export function encodeACR(canonical) {
  const ledger = { deviations: [], extensions: [], losses: [] }
  ledger.deviations.push(
    'prototype entry vocabulary is not VAC -00 CDDL-shaped (`entry-id`/`role`/`arguments`/`content` differ from the pinned draft); self-decode is not conformance evidence.')
  const entries = []
  let counter = 0
  const spawnEntryByAgent = new Map()
  const semanticEvent = (event) => {
    const copy = structuredClone(event)
    delete copy.eventId
    delete copy.observedAt
    delete copy.timeProvenance
    return copy
  }

  const push = (entry, ownerAgentId) => {
    entry['entry-id'] = `e-${counter += 1}`
    if (ownerAgentId && ownerAgentId !== 'root') {
      // Nesting: parent the entry under the owning agent's spawn entry, expressing the
      // delegation TREE the way the CDDL intends (parent-id), not as flat siblings.
      const parent = spawnEntryByAgent.get(ownerAgentId)
      if (parent) entry['parent-id'] = parent
      entry['x-agent-id'] = ownerAgentId
    }
    entries.push(entry)
    return entry['entry-id']
  }

  for (const event of canonical.events) {
    const firstEntryIndex = entries.length
    switch (event.kind) {
      case 'user_message':
        push({
          type: 'message', role: 'user', content: event.text, timestamp: event.observedAt,
          'x-turn-id': event.turnId,
        })
        break
      case 'assistant_message':
        push({
          type: 'message', role: 'assistant', content: event.text, timestamp: event.observedAt,
          'x-turn-id': event.turnId,
        }, event.agentId)
        break
      case 'agent_spawn': {
        // No native spawn vocabulary: a system event-entry carries it (spec: event-type is
        // deliberately open, vac l.1592-1594). The spawned agent's subsequent entries parent
        // under this entry, forming the delegation tree.
        const spawned = canonical.agents.find((a) => a.id === event.spawnedAgentId)
        const id = push({
          type: 'system-event', 'event-type': 'agent-spawn',
          data: {
            'x-agent-id': event.spawnedAgentId,
            'x-spawn-call-id': event.toolUseId,
            'x-agent-type': spawned?.type ?? 'agent',
            'x-agent-task': event.task ?? spawned?.task,
            'x-spawn-provenance': event.spawnProvenance ?? null,
            'x-parentage-provenance': spawned?.parentageProvenance ?? null,
            'x-workflow-id': spawned?.workflowId ?? null,
            'x-phase-id': spawned?.phaseId ?? null,
            'x-source-ordinal': spawned?.sourceOrdinal ?? null,
            'x-logical-agent-path': spawned?.logicalAgentPath ?? null,
            'x-agent-identity-provenance': spawned?.identityProvenance ?? null,
          },
          timestamp: event.observedAt,
        }, event.agentId)
        spawnEntryByAgent.set(event.spawnedAgentId, id)
        ledger.extensions.push(
          `agent-spawn for ${event.spawnedAgentId}: expressed as an open event-entry + x-agent-id members — no native spawn/lifecycle vocabulary exists in VAC -00.`)
        break
      }
      case 'agent_message':
        push({
          type: 'tool-call', 'call-id': event.toolUseId, name: 'SendMessage',
          arguments: { recipient: event.recipientAgentId, summary: event.summary },
          'x-recipient-agent-id': event.recipientAgentId,
          'x-turn-id': event.turnId,
          timestamp: event.observedAt,
        }, event.agentId)
        ledger.extensions.push(
          `agent-to-agent message ${event.agentId} -> ${event.recipientAgentId}: recipient carried only by the x-recipient-agent-id extension member; a non-extension reader sees an ordinary tool call.`)
        break
      case 'tool_call':
        push({
          type: 'tool-call', 'call-id': event.toolUseId, name: event.name,
          arguments: event.input ?? {}, 'x-turn-id': event.turnId, timestamp: event.observedAt,
        }, event.agentId)
        break
      case 'agent_call_result': {
        const completedAgentID = event.completedAgentId
          ?? canonical.agents.find((agent) => agent.id === event.toolUseId)?.id
        push({
          type: 'tool-result', 'call-id': event.toolUseId,
          content: event.result, 'is-error': event.isError, 'x-turn-id': event.turnId,
          'x-completed-agent-id': completedAgentID,
          'x-outcome': event.outcome,
          'x-status': event.status,
          'x-disposition': event.disposition,
          'x-provider-task-id-present': event.providerTaskIdPresent,
          'x-state-provenance': event.stateProvenance,
          timestamp: event.observedAt,
        }, event.agentId)
        ledger.extensions.push(
          'agent call result lifecycle: outcome, status, disposition, provider-task presence and state provenance use x- extension members; VAC -00 has no native equivalent.')
        break
      }
      case 'tool_result':
        push({
          type: 'tool-result', 'call-id': event.toolUseId,
          content: event.result, 'is-error': event.isError, 'x-turn-id': event.turnId,
          'x-outcome': event.outcome,
          'x-status': event.status,
          'x-state-provenance': event.stateProvenance,
          timestamp: event.observedAt,
        }, event.agentId)
        ledger.extensions.push(
          'tool result lifecycle: outcome, status and state provenance use x- extension members beyond the VAC -00 result vocabulary.')
        break
      case 'tool_terminal':
        push({
          type: 'system-event', 'event-type': 'tool-terminal',
          data: {
            'turn-id': event.turnId, 'tool-use-id': event.toolUseId,
            outcome: event.outcome, 'state-provenance': event.stateProvenance,
            'provider-observed': event.providerObserved,
          },
          timestamp: event.observedAt,
        }, event.agentId)
        ledger.extensions.push(
          'tool terminal without a provider result: carried as an open event-entry with explicit observation provenance.')
        break
      case 'session':
        push({
          type: 'system-event', 'event-type': 'session-start',
          data: { 'session-ref': event.sessionId, 'turn-id': event.turnId },
          timestamp: event.observedAt,
        })
        break
      case 'turn_started':
        push({
          type: 'system-event', 'event-type': 'turn-started',
          data: { 'turn-id': event.turnId }, timestamp: event.observedAt,
        })
        ledger.extensions.push(
          'turn lifecycle: carried as open event-entry values because VAC -00 has no complete turn lifecycle vocabulary.')
        break
      case 'turn_completed':
        push({
          type: 'system-event', 'event-type': 'turn-completed',
          data: { 'turn-id': event.turnId },
          timestamp: event.observedAt,
        })
        break
      case 'turn_stopped':
        push({
          type: 'system-event', 'event-type': 'turn-stopped',
          data: { 'turn-id': event.turnId }, timestamp: event.observedAt,
        })
        ledger.extensions.push(
          'stopped turn lifecycle: carried as an open event-entry because VAC -00 has no complete turn lifecycle vocabulary.')
        break
      case 'turn_failed':
        push({
          type: 'system-event', 'event-type': 'turn-failed',
          data: { 'turn-id': event.turnId, 'error-kind': event.errorKind },
          timestamp: event.observedAt,
        })
        ledger.extensions.push(
          'failed turn lifecycle: carried as an open event-entry because VAC -00 has no complete turn lifecycle vocabulary.')
        break
      case 'usage':
        push({
          type: 'system-event', 'event-type': 'token-usage',
          data: {
            'turn-id': event.turnId,
            input: event.inputTokens,
            'cached-input': event.cachedInputTokens,
            output: event.outputTokens,
            'reasoning-output': event.reasoningOutputTokens,
          },
          timestamp: event.observedAt,
        }, event.agentId)
        ledger.extensions.push(
          'turn-scoped usage: represented as an open event-entry so attribution and event order remain explicit.')
        break
      case 'agent_lifecycle':
        push({
          type: 'system-event', 'event-type': 'agent-lifecycle',
          data: { 'x-canonical-event': semanticEvent(event) },
          timestamp: event.observedAt,
        }, event.agentId)
        ledger.extensions.push(
          'detailed agent lifecycle: carried as an open event-entry; VAC -00 has no native per-agent lifecycle state model.')
        break
      case 'workflow_invocation':
      case 'workflow_lifecycle':
      case 'workflow_usage':
      case 'workflow_phase_lifecycle':
      case 'workflow_progress_observation':
      case 'agent_tool_observation':
        push({
          type: 'system-event', 'event-type': event.kind.replaceAll('_', '-'),
          data: { 'x-canonical-event': semanticEvent(event) },
          timestamp: event.observedAt,
        }, event.agentId)
        ledger.extensions.push(
          `${event.kind}: carried as a namespaced canonical event extension; VAC -00 has no native workflow graph/lifecycle vocabulary.`)
        break
      case 'provider_error':
        push({
          type: 'system-event', 'event-type': 'provider-error',
          data: {
            'turn-id': event.turnId,
            'error-kind': event.errorKind,
            'rate-limit-type': event.rateLimitType,
            'resets-at': event.resetsAt,
            message: event.message,
          },
          timestamp: event.observedAt,
        }, event.agentId)
        ledger.extensions.push(
          'provider error lifecycle: carried as an open event-entry with safe normalized fields.')
        break
      case 'steering':
        push({
          type: 'system-event', 'event-type': 'steering',
          data: {
            'turn-id': event.turnId,
            'steering-id': event.steeringId,
            'requester-agent-id': event.requesterAgentId,
            state: event.state,
          },
          timestamp: event.observedAt,
        }, event.agentId)
        ledger.extensions.push(
          'steering lifecycle: carried as an open event-entry; no native VAC -00 authorization/steering vocabulary exists.')
        break
      case 'steering_request':
        push({
          type: 'system-event', 'event-type': 'steering-request',
          data: {
            'turn-id': event.turnId,
            'steering-id': event.steeringId,
            'responder-agent-id': event.responderAgentId,
            text: event.text,
          },
          timestamp: event.observedAt,
        }, event.agentId)
        ledger.extensions.push(
          'steering request content: carried as an open event-entry; no native VAC -00 authorization/steering vocabulary exists.')
        break
      case 'authorization_request':
        push({
          type: 'system-event', 'event-type': 'authorization-request',
          data: {
            'turn-id': event.turnId, 'interaction-id': event.interactionId,
            'recipient-agent-id': event.recipientAgentId, 'tool-name': event.toolName,
            input: event.input, 'boundary-request': event.boundaryRequest,
            'input-disclosure': event.inputDisclosure,
            capability: event.capability, 'historical-only': event.historicalOnly,
          }, timestamp: event.observedAt,
        }, event.agentId)
        ledger.extensions.push(
          'authorization request: carried as an open event-entry; VAC -00 has no permission lifecycle vocabulary.')
        break
      case 'authorization_response':
        push({
          type: 'system-event', 'event-type': 'authorization-response',
          data: {
            'turn-id': event.turnId, 'interaction-id': event.interactionId,
            'recipient-agent-id': event.recipientAgentId, decision: event.decision,
            'requested-scope': event.requestedScope,
            message: event.message,
            'operative-grant-included': event.operativeGrantIncluded,
            'delivery-attempts': event.deliveryAttempts,
            'response-status': event.responseStatus,
            'historical-only': event.historicalOnly,
          }, timestamp: event.observedAt,
        }, event.agentId)
        ledger.extensions.push(
          'authorization decision: carried as inert history in an open event-entry; no operative grant is included.')
        break
      case 'authorization_ack':
        push({
          type: 'system-event', 'event-type': 'authorization-ack',
          data: {
            'turn-id': event.turnId, 'interaction-id': event.interactionId,
            'recipient-agent-id': event.recipientAgentId,
            accepted: event.accepted, message: event.message,
            'response-status': event.responseStatus,
            'decision-matched': event.decisionMatched,
            'historical-only': event.historicalOnly,
          }, timestamp: event.observedAt,
        }, event.agentId)
        ledger.extensions.push(
          'authorization acknowledgement: carried as an open event-entry distinct from the user decision attempt.')
        break
      case 'question':
        push({
          type: 'system-event', 'event-type': 'question',
          data: {
            'turn-id': event.turnId, 'interaction-id': event.interactionId,
            'recipient-agent-id': event.recipientAgentId, questions: event.questions,
            'content-status': event.contentStatus, 'historical-only': event.historicalOnly,
          }, timestamp: event.observedAt,
        }, event.agentId)
        ledger.extensions.push(
          'question request: carried as an open event-entry; VAC -00 has no interactive question lifecycle vocabulary.')
        break
      case 'answer':
        push({
          type: 'system-event', 'event-type': 'answer',
          data: {
            'turn-id': event.turnId, 'interaction-id': event.interactionId,
            'recipient-agent-id': event.recipientAgentId, answers: event.answers,
            response: event.response, 'delivery-attempts': event.deliveryAttempts,
            'response-status': event.responseStatus,
            'content-status': event.contentStatus, 'historical-only': event.historicalOnly,
          }, timestamp: event.observedAt,
        }, event.agentId)
        ledger.extensions.push(
          'question answer: carried as an open event-entry distinct from provider acknowledgement.')
        break
      case 'answer_ack':
        push({
          type: 'system-event', 'event-type': 'answer-ack',
          data: {
            'turn-id': event.turnId, 'interaction-id': event.interactionId,
            'recipient-agent-id': event.recipientAgentId,
            accepted: event.accepted, message: event.message,
            'response-status': event.responseStatus,
            'historical-only': event.historicalOnly,
          }, timestamp: event.observedAt,
        }, event.agentId)
        ledger.extensions.push(
          'question acknowledgement: carried as an open event-entry distinct from the user answer.')
        break
      case 'interaction_closed':
        push({
          type: 'system-event', 'event-type': 'interaction-closed',
          data: {
            'turn-id': event.turnId, 'interaction-id': event.interactionId,
            'recipient-agent-id': event.recipientAgentId,
            'interaction-type': event.interactionType,
            outcome: event.outcome, reason: event.reason,
            'historical-only': event.historicalOnly,
          }, timestamp: event.observedAt,
        }, event.agentId)
        ledger.extensions.push(
          'interaction closure without a response: carried as an open event-entry; VAC -00 has no terminal permission/question lifecycle vocabulary.')
        break
      case 'interruption_requested':
        push({
          type: 'system-event', 'event-type': 'interruption-requested',
          data: {
            'turn-id': event.turnId, 'recipient-agent-id': event.recipientAgentId,
          }, timestamp: event.observedAt,
        }, event.agentId)
        ledger.extensions.push(
          'interruption intent: carried as an open event-entry distinct from the observed stopped terminal.')
        break
      case 'compaction':
        push({
          type: 'system-event', 'event-type': 'context-compaction',
          data: {
            trigger: event.trigger,
            'pre-tokens': event.preTokens, 'post-tokens': event.postTokens,
            'turn-id': event.turnId,
          },
          timestamp: event.observedAt,
        }, event.agentId)
        ledger.extensions.push(
          'context compaction: no native vocabulary in VAC -00 or Agent Session -00 (recorded fit gap) — carried as an open event-entry.')
        break
      case 'context_usage':
        push({
          type: 'system-event', 'event-type': 'context-usage',
          data: {
            'context-tokens': event.contextTokens,
            'context-window': event.contextWindow,
            model: event.model,
            'turn-id': event.turnId,
          },
          timestamp: event.observedAt,
        }, event.agentId)
        ledger.extensions.push(
          'context usage: no native vocabulary in VAC -00 or Agent Session -00 — carried as an open event-entry.')
        break
      case 'system':
        push({
          type: 'system-event', 'event-type': 'app-system-note',
          data: { note: event.text, 'source-kind': event.sourceKind },
          timestamp: event.observedAt,
        }, event.agentId)
        break
      default:
        ledger.losses.push(`event kind ${event.kind} has no VAC mapping and was dropped`)
    }
    for (let index = firstEntryIndex; index < entries.length; index += 1) {
      entries[index]['x-event-id'] = event.eventId
    }
  }
  if (canonical.events.length) {
    ledger.extensions.push(
      'stable event identity: carried in x-event-id extension members because VAC -00 has no record-wide event identity vocabulary.')
  }

  ledger.losses.push(
    'per-record agent-meta names ONE agent; the other agents\' identities/models exist only in x-agent-id extension members — a conformant non-extension reader attributes every entry to the root agent.')

  const record = {
    version: '1.0',
    id: `mechanician-spike-${canonical.sessionIds[0] ?? 'session'}`,
    session: {
      'session-id': canonical.sessionIds[0] ?? 'session-1',
      'session-start': canonical.events[0]?.observedAt ?? '1990-01-01T00:00:00Z',
      'agent-meta': {
        'model-id': 'fixture-model',
        'model-provider': 'mechanician-fixture',
        'cli-name': 'mechanician-spike',
      },
      entries,
    },
    ...(canonical.workflows !== undefined
      ? { 'x-mechanician-workflows': structuredClone(canonical.workflows) }
      : {}),
    ...(canonical.workflowPhases !== undefined
      ? { 'x-mechanician-workflow-phases': structuredClone(canonical.workflowPhases) }
      : {}),
  }
  if ((canonical.workflows?.length ?? 0) || (canonical.workflowPhases?.length ?? 0)) {
    ledger.extensions.push(
      'workflow and phase identity graphs: carried in namespaced top-level extensions; VAC -00 models neither construct.')
  }
  if (canonical.producer) {
    record['x-mechanician-producer'] = canonical.producer
    ledger.extensions.push(
      'producer metadata: carried in a namespaced top-level extension for fit-gap round-trip evidence.')
  }
  if (canonical.profile) {
    record['x-mechanician-profile'] = canonical.profile
    ledger.extensions.push(
      'profile declaration: carried in a namespaced top-level extension for fit-gap round-trip evidence.')
  }
  return { record, ledger }
}

/// Decode a VAC record back to the canonical skeleton — reading BOTH the conformant structure
/// and the declared x- extension members (the round-trip proves what survives WITH the
/// extensions; the ledger already states what a non-extension reader loses).
export function decodeACRRecord(record) {
  const agents = [{ id: 'root', parentId: null, type: 'root', task: null }]
  const events = []
  const sessionIds = []
  const spawnOwnerByEntryId = new Map()

  for (const entry of record.session.entries) {
    const firstEventIndex = events.length
    const owner = entry['x-agent-id']
      ?? (entry['parent-id'] ? spawnOwnerByEntryId.get(entry['parent-id']) : null)
      ?? 'root'
    switch (entry.type) {
      case 'message':
        events.push({
          kind: entry.role === 'user' ? 'user_message' : 'assistant_message',
          agentId: entry.role === 'user' ? 'user' : owner,
          text: entry.content, turnId: entry['x-turn-id'],
        })
        break
      case 'system-event':
        if (entry['event-type'] === 'agent-spawn') {
          const spawned = entry.data['x-agent-id']
          const agent = { id: spawned, parentId: owner, type: entry.data['x-agent-type'] }
          // Preserve the prototype's declared legacy task-decoding gap for ordinary agents. A
          // workflow-progress actor has no task property by design, so do not manufacture one.
          if (entry.data['x-workflow-id'] == null) agent.task = ''
          if (entry.data['x-parentage-provenance'] != null) {
            agent.parentageProvenance = entry.data['x-parentage-provenance']
          }
          if (entry.data['x-workflow-id'] != null) agent.workflowId = entry.data['x-workflow-id']
          if (entry.data['x-phase-id'] != null) agent.phaseId = entry.data['x-phase-id']
          if (entry.data['x-source-ordinal'] != null) {
            agent.sourceOrdinal = entry.data['x-source-ordinal']
          }
          if (entry.data['x-logical-agent-path'] != null) {
            agent.logicalAgentPath = entry.data['x-logical-agent-path']
          }
          if (entry.data['x-agent-identity-provenance'] != null) {
            agent.identityProvenance = entry.data['x-agent-identity-provenance']
          }
          agents.push(agent)
          spawnOwnerByEntryId.set(entry['entry-id'], spawned)
          const spawnEvent = { kind: 'agent_spawn', agentId: owner, spawnedAgentId: spawned }
          if (entry.data['x-spawn-call-id'] != null) {
            spawnEvent.toolUseId = entry.data['x-spawn-call-id']
          }
          if (entry.data['x-agent-type'] != null) spawnEvent.agentType = entry.data['x-agent-type']
          if (entry.data['x-agent-task'] != null) spawnEvent.task = entry.data['x-agent-task']
          if (entry.data['x-spawn-provenance'] != null) {
            spawnEvent.spawnProvenance = entry.data['x-spawn-provenance']
          }
          if (entry.data['x-workflow-id'] != null) {
            spawnEvent.workflowId = entry.data['x-workflow-id']
          }
          if (entry.data['x-phase-id'] != null) spawnEvent.phaseId = entry.data['x-phase-id']
          if (entry.data['x-source-ordinal'] != null) {
            spawnEvent.sourceOrdinal = entry.data['x-source-ordinal']
          }
          events.push(spawnEvent)
        } else if (entry['event-type'] === 'session-start') {
          sessionIds.push(entry.data['session-ref'])
          events.push({
            kind: 'session', sessionId: entry.data['session-ref'], turnId: entry.data['turn-id'],
          })
        } else if (entry['event-type'] === 'turn-started') {
          events.push({
            kind: 'turn_started', agentId: 'root', turnId: entry.data['turn-id'],
          })
        } else if (entry['event-type'] === 'turn-completed') {
          events.push({
            kind: 'turn_completed', agentId: 'root', turnId: entry.data?.['turn-id'],
          })
        } else if (entry['event-type'] === 'turn-stopped') {
          events.push({
            kind: 'turn_stopped', agentId: 'root', turnId: entry.data?.['turn-id'],
          })
        } else if (entry['event-type'] === 'turn-failed') {
          events.push({
            kind: 'turn_failed', agentId: 'root', turnId: entry.data?.['turn-id'],
            errorKind: entry.data?.['error-kind'],
          })
        } else if (entry['event-type'] === 'token-usage') {
          events.push({
            kind: 'usage', agentId: owner, turnId: entry.data['turn-id'],
            inputTokens: entry.data.input,
            cachedInputTokens: entry.data['cached-input'],
            outputTokens: entry.data.output,
            reasoningOutputTokens: entry.data['reasoning-output'],
          })
        } else if (entry['event-type'] === 'agent-lifecycle') {
          const expanded = entry.data['x-canonical-event']
          if (expanded) {
            const legacyFields = [
              ['turn-id', 'turnId'], ['agent-id', 'agentId'], ['phase', 'phase'],
              ['state', 'state'], ['outcome', 'outcome'], ['task-id', 'taskId'],
              ['tool-use-id', 'toolUseId'], ['task-type', 'taskType'],
              ['subagent-type', 'subagentType'], ['description', 'description'],
              ['summary', 'summary'], ['last-tool-name', 'lastToolName'],
              ['result-preview', 'resultPreview'], ['observed-model', 'observedModel'],
              ['usage', 'usage'], ['error', 'error'],
            ]
            for (const [legacyKey, canonicalKey] of legacyFields) {
              if (!Object.hasOwn(entry.data, legacyKey)) continue
              if (JSON.stringify(entry.data[legacyKey])
                  !== JSON.stringify(expanded[canonicalKey])) {
                throw new Error(
                  `agent-lifecycle ordinary field ${legacyKey} conflicts with x-canonical-event`)
              }
            }
            events.push(structuredClone(expanded))
          } else {
            events.push({
              kind: 'agent_lifecycle', agentId: entry.data['agent-id'] ?? owner,
              turnId: entry.data['turn-id'], phase: entry.data.phase, state: entry.data.state,
              outcome: entry.data.outcome,
              taskId: entry.data['task-id'], toolUseId: entry.data['tool-use-id'],
              taskType: entry.data['task-type'], subagentType: entry.data['subagent-type'],
              description: entry.data.description, summary: entry.data.summary,
              lastToolName: entry.data['last-tool-name'],
              resultPreview: entry.data['result-preview'],
              observedModel: entry.data['observed-model'],
              usage: entry.data.usage, error: entry.data.error,
            })
          }
        } else if (entry.data?.['x-canonical-event']) {
          events.push(structuredClone(entry.data['x-canonical-event']))
        } else if (entry['event-type'] === 'provider-error') {
          events.push({
            kind: 'provider_error', agentId: owner, turnId: entry.data['turn-id'],
            errorKind: entry.data['error-kind'], rateLimitType: entry.data['rate-limit-type'],
            resetsAt: entry.data['resets-at'], message: entry.data.message,
          })
        } else if (entry['event-type'] === 'tool-terminal') {
          events.push({
            kind: 'tool_terminal', agentId: owner,
            turnId: entry.data['turn-id'], toolUseId: entry.data['tool-use-id'],
            outcome: entry.data.outcome,
            stateProvenance: entry.data['state-provenance'],
            providerObserved: entry.data['provider-observed'],
          })
        } else if (entry['event-type'] === 'steering') {
          events.push({
            kind: 'steering', agentId: owner, turnId: entry.data['turn-id'],
            steeringId: entry.data['steering-id'],
            requesterAgentId: entry.data['requester-agent-id'], state: entry.data.state,
          })
        } else if (entry['event-type'] === 'steering-request') {
          events.push({
            kind: 'steering_request', agentId: owner, turnId: entry.data['turn-id'],
            steeringId: entry.data['steering-id'],
            responderAgentId: entry.data['responder-agent-id'], text: entry.data.text,
          })
        } else if (entry['event-type'] === 'authorization-request') {
          events.push({
            kind: 'authorization_request', agentId: owner,
            recipientAgentId: entry.data['recipient-agent-id'],
            turnId: entry.data['turn-id'], interactionId: entry.data['interaction-id'],
            toolName: entry.data['tool-name'], input: entry.data.input,
            inputDisclosure: entry.data['input-disclosure'],
            boundaryRequest: entry.data['boundary-request'], capability: entry.data.capability,
            historicalOnly: entry.data['historical-only'],
          })
        } else if (entry['event-type'] === 'authorization-response') {
          events.push({
            kind: 'authorization_response', agentId: owner,
            recipientAgentId: entry.data['recipient-agent-id'],
            turnId: entry.data['turn-id'], interactionId: entry.data['interaction-id'],
            decision: entry.data.decision, requestedScope: entry.data['requested-scope'],
            message: entry.data.message,
            operativeGrantIncluded: entry.data['operative-grant-included'],
            deliveryAttempts: entry.data['delivery-attempts'],
            responseStatus: entry.data['response-status'],
            historicalOnly: entry.data['historical-only'],
          })
        } else if (entry['event-type'] === 'authorization-ack') {
          events.push({
            kind: 'authorization_ack', agentId: owner,
            recipientAgentId: entry.data['recipient-agent-id'],
            turnId: entry.data['turn-id'], interactionId: entry.data['interaction-id'],
            accepted: entry.data.accepted, message: entry.data.message,
            responseStatus: entry.data['response-status'],
            decisionMatched: entry.data['decision-matched'],
            historicalOnly: entry.data['historical-only'],
          })
        } else if (entry['event-type'] === 'question') {
          events.push({
            kind: 'question', agentId: owner,
            recipientAgentId: entry.data['recipient-agent-id'],
            turnId: entry.data['turn-id'], interactionId: entry.data['interaction-id'],
            questions: entry.data.questions, contentStatus: entry.data['content-status'],
            historicalOnly: entry.data['historical-only'],
          })
        } else if (entry['event-type'] === 'answer') {
          events.push({
            kind: 'answer', agentId: owner,
            recipientAgentId: entry.data['recipient-agent-id'],
            turnId: entry.data['turn-id'], interactionId: entry.data['interaction-id'],
            answers: entry.data.answers, response: entry.data.response,
            deliveryAttempts: entry.data['delivery-attempts'],
            responseStatus: entry.data['response-status'],
            contentStatus: entry.data['content-status'],
            historicalOnly: entry.data['historical-only'],
          })
        } else if (entry['event-type'] === 'answer-ack') {
          events.push({
            kind: 'answer_ack', agentId: owner,
            recipientAgentId: entry.data['recipient-agent-id'],
            turnId: entry.data['turn-id'], interactionId: entry.data['interaction-id'],
            accepted: entry.data.accepted, message: entry.data.message,
            responseStatus: entry.data['response-status'],
            historicalOnly: entry.data['historical-only'],
          })
        } else if (entry['event-type'] === 'interaction-closed') {
          events.push({
            kind: 'interaction_closed', agentId: owner,
            recipientAgentId: entry.data['recipient-agent-id'],
            turnId: entry.data['turn-id'], interactionId: entry.data['interaction-id'],
            interactionType: entry.data['interaction-type'],
            outcome: entry.data.outcome, reason: entry.data.reason,
            historicalOnly: entry.data['historical-only'],
          })
        } else if (entry['event-type'] === 'interruption-requested') {
          events.push({
            kind: 'interruption_requested', agentId: owner,
            recipientAgentId: entry.data['recipient-agent-id'], turnId: entry.data['turn-id'],
          })
        } else if (entry['event-type'] === 'context-compaction') {
          events.push({
            kind: 'compaction', agentId: owner, trigger: entry.data.trigger,
            preTokens: entry.data['pre-tokens'], postTokens: entry.data['post-tokens'],
            turnId: entry.data['turn-id'],
          })
        } else if (entry['event-type'] === 'context-usage') {
          events.push({
            kind: 'context_usage', agentId: owner,
            contextTokens: entry.data['context-tokens'],
            contextWindow: entry.data['context-window'],
            model: entry.data.model, turnId: entry.data['turn-id'],
          })
        } else if (entry['event-type'] === 'app-system-note') {
          events.push({
            kind: 'system', agentId: owner, text: entry.data.note,
            sourceKind: entry.data['source-kind'],
          })
        }
        break
      case 'tool-call':
        if (entry['x-recipient-agent-id']) {
          events.push({
            kind: 'agent_message', agentId: owner,
            recipientAgentId: entry['x-recipient-agent-id'],
            toolUseId: entry['call-id'], turnId: entry['x-turn-id'],
          })
        } else {
          events.push({
            kind: 'tool_call', agentId: owner, toolUseId: entry['call-id'], name: entry.name,
            turnId: entry['x-turn-id'],
          })
        }
        break
      case 'tool-result': {
        const completedAgentID = entry['x-completed-agent-id']
        events.push({
          kind: completedAgentID ? 'agent_call_result' : 'tool_result',
          agentId: owner, toolUseId: entry['call-id'],
          result: entry.content, isError: entry['is-error'], turnId: entry['x-turn-id'],
          outcome: entry['x-outcome'],
          status: entry['x-status'], stateProvenance: entry['x-state-provenance'],
          ...(completedAgentID ? {
            completedAgentId: completedAgentID,
            disposition: entry['x-disposition'],
            providerTaskIdPresent: entry['x-provider-task-id-present'],
          } : {}),
        })
        break
      }
      default:
        break
    }
    for (let index = firstEventIndex; index < events.length; index += 1) {
      if (entry['x-event-id'] != null) events[index].eventId = entry['x-event-id']
    }
  }
  const decoded = {
    format: 'mechanician-canonical-graph/0-spike',
    sessionIds,
    agents,
    ...(record['x-mechanician-workflows'] !== undefined
      ? { workflows: structuredClone(record['x-mechanician-workflows']) }
      : {}),
    ...(record['x-mechanician-workflow-phases'] !== undefined
      ? { workflowPhases: structuredClone(record['x-mechanician-workflow-phases']) }
      : {}),
    events,
  }
  if (record['x-mechanician-producer']) decoded.producer = record['x-mechanician-producer']
  if (record['x-mechanician-profile']) decoded.profile = record['x-mechanician-profile']
  // The fit-gap encoder may have been handed an older selected-subset canonical object. Strip
  // optional members that were absent at the source rather than converting absence into an
  // authoritative `null`/undefined fact.
  return JSON.parse(JSON.stringify(decoded))
}
