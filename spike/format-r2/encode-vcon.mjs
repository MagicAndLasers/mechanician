// Root A: canonical graph -> vCon core -03 + agent_session binding, embedded VAC trace.
// Written against specs/vcon-core.md and specs/agent-session.md (pinned-draft citations there).
// Every draft-forced choice is a recorded `deviation`; every fact carried through an
// extensibility escape hatch is classified `extension`; anything unrepresentable is `loss`.
import crypto from 'node:crypto'
import { encodeACR } from './encode-acr.mjs'

export function encodeVcon(canonical) {
  const ledger = { deviations: [], extensions: [], losses: [] }
  ledger.deviations.push(
    'agent parties omit the Agent Session binding-required meta.agent_session model_id/provider fields; this prototype is vCon-shaped fit-gap evidence, not Agent Session conformance.')
  ledger.deviations.push(
    'decoder reads only the embedded provisional VAC trace and does not cross-check duplicated dialog text/attribution; dialog/trace divergence remains an explicit format-review blocker.')

  // Parties: user first, then one party PER distinct agent (MUST — agent-session L258-260,
  // L317-319). Party index map drives every dialog/attachment reference.
  const parties = [{ name: 'user', type: 'person' }]
  const partyIndex = new Map([['user', 0]])
  for (const agent of canonical.agents) {
    partyIndex.set(agent.id, parties.length)
    parties.push({
      name: agent.id === 'root' ? 'root agent' : `${agent.type} ${agent.id}`,
      // Emit BOTH core -03's `type: "bot"` and the binding's `role: "agent"` — the binding was
      // written against core -02 and `role` does not exist in -03 (spec §6, trap 1).
      type: 'bot',
      role: 'agent',
      uuid: agent.id,
    })
  }
  ledger.deviations.push(
    'party role="agent" emitted alongside core -03 type="bot": the agent_session binding requires a `role` key that core -03 does not define (binding L259 vs core key registry).')

  // Dialog: visible user/assistant messages only — the human-facing projection. `start` is
  // REQUIRED by core; our fixtures carry no provider times, so capture-approximate observation
  // times are used and DECLARED (never fabricated as provider truth).
  const dialog = []
  const dialogIndexByEvent = new Map()
  for (const [i, event] of canonical.events.entries()) {
    if (event.kind !== 'user_message' && event.kind !== 'assistant_message') continue
    dialogIndexByEvent.set(i, dialog.length)
    dialog.push({
      type: 'text',
      start: event.observedAt ?? '1990-01-01T00:00:00.000+00:00',
      parties: [partyIndex.get(event.kind === 'user_message' ? 'user' : event.agentId) ?? 0],
      mediatype: 'text/plain',
      body: event.text,
      encoding: 'none',
    })
  }
  ledger.deviations.push(
    'dialog start times are capture-approximate observation times, declared as such (core requires start; the wire provides no provider event time — a Stage A capture gap).')

  // The execution trace rides as ONE whole-session agent_trace analysis (RECOMMENDED for
  // archival, binding L407) whose body is the root-B VAC record — object body, `session` key.
  const acr = encodeACR(canonical)
  ledger.deviations.push(...acr.ledger.deviations)
  ledger.deviations.push(
    'agent_trace body emitted as a JSON OBJECT under the CDDL key `session`: the binding example stringifies the body and names the key `session-trace` (L358/L379), both of which contradict core -03 encoding="json" semantics and the VAC CDDL (vac L1088). Sides picked per spec trap notes; fit gap recorded.')
  ledger.extensions.push(...acr.ledger.extensions)
  ledger.losses.push(...acr.ledger.losses)

  const rootAgent = canonical.agents.find((a) => a.id === 'root')
  const analysis = [{
    type: 'agent_trace',
    dialog: dialog.map((_, i) => i),
    vendor: 'mechanician-fixture',
    product: rootAgent?.type ?? 'root',
    schema: 'https://datatracker.ietf.org/doc/draft-birkholz-verifiable-agent-conversations/',
    encoding: 'json',
    body: acr.record,
  }]

  const vcon = {
    uuid: crypto.randomUUID(),
    created_at: canonical.events[0]?.observedAt ?? new Date().toISOString(),
    extensions: ['agent_session'],
    parties,
    dialog,
    analysis,
  }
  ledger.deviations.push(
    'top-level uuid is UUIDv4: core SHOULD-level asks for UUIDv8 derived from a signing-domain FQHN (core l.791-804); the spike has no domain identity yet.')
  return { vcon, ledger }
}

/// Best-effort decode back to the canonical skeleton through the spike's own provisional VAC
/// extension vocabulary. This is round-trip fit-gap evidence, not an independent or conformant
/// vCon/Agent Session/VAC reader; the deviation ledger above is the authoritative qualification.
export function decodeVcon(encoded) {
  const { vcon } = encoded
  const body = vcon.analysis?.[0]?.body
  const { decodeACRRecord } = requireDecodeACR()
  return decodeACRRecord(body)
}

// Lazy import to avoid a cycle at module load.
import * as acrModule from './encode-acr.mjs'
function requireDecodeACR() { return acrModule }
