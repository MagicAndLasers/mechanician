# Initial-response performance, proactive context maintenance, and agent-card implementation plan

> **Archived on 2026-08-07. This is a planning document, not a description of the app.**
>
> It was written on 2026-07-28 and abandoned part-built. Some of it shipped and some of it did not,
> and the document itself does not distinguish them, so do not read any statement here as a claim
> about current behaviour. Two examples of the gap: the Claude send-time context guard did ship and
> is `agentd/src/claude-context-guard.mjs`, with the reserve constants named below intact in
> `CLAUDE_CONTEXT_POLICY`; the `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE` threshold control described below
> was never implemented, and
> `grep -rn CLAUDE_AUTOCOMPACT_PCT_OVERRIDE agentd/src app/Sources scripts` finds nothing.
> The shared proactive-maintenance controller the plan is built around was never written either.
>
> Read it for the reasoning, in particular for the distinction it draws between native compaction,
> session rollover, and bounded history replay, which is a real distinction the shipped code still
> honours. Do not read it as a specification and do not implement from it.
>
> For what actually ships: the provider lanes and their context handling are in
> [docs/architecture/PROVIDER-LANES-AND-ACCOUNTS.md](../architecture/PROVIDER-LANES-AND-ACCOUNTS.md),
> the daemon side in
> [docs/architecture/AGENTD-INTERNALS.md](../architecture/AGENTD-INTERNALS.md), and the Agents panel
> and its cards in [docs/architecture/APP-SHELL-AND-UI.md](../architecture/APP-SHELL-AND-UI.md).
> [The history index](README.md) lists everything else in this directory.

Prepared: 2026-07-28
Implementation started: 2026-07-29
Manual and explicit context controls were tracked separately and are not superseded by this plan.

## Outcome

This program has six user-visible outcomes:

1. A resumed, high-context Claude or Codex conversation does not spend a minute silently
   prefilling old history or reach an avoidable late-compaction failure before its first response.
2. Every agent card distinguishes provider, agent role/type, and model, and
   shows the provider-reported model whenever that information is available.
3. The Agents panel keeps its conversation-wide summary and adds a separate
   root-agent card with root-only state, tokens, duration, and observed tool use.
4. Agent Stop controls use the same octagonal road-sign artwork as the composer,
   instead of an unrelated red square.
5. Main agents call already-exposed MCP tools directly and never take a
   ToolSearch/subagent detour because generated instructions describe a
   capability that is not actually present.
6. Claude credential and connection failure cards provide a working reconnect
   action at the point of failure.

The latency work is P0. The model-attribution work is a data dependency of the
root card. The stop-sign change is independent and can be implemented in
parallel.

## Implementation progress

Completed on 2026-07-29:

- Pinned and verified the exact Codex compaction, token-usage, model-update,
  thread-read, and item-list protocol shapes.
- Prototyped the pure proactive-maintenance policy and isolated lifecycle
  controller against the captured 220,607-of-258,400-token regression case.
  The prototypes were deliberately removed from the release candidate after
  review because no production adapter owned their state yet; they remain in
  repository history for the production integration work.
- Added Claude's authoritative send-time context preflight and side-effect-safe bounded-session
  recovery after a native compaction failure. That closes the oversized-request fallthrough, but
  it is emergency recovery rather than the proactive policy this plan calls for.
- Stopped fabricating zero pre/post token counts when Codex does not report
  them.
- Added a shared cached road-sign image renderer and migrated every existing
  agent/workflow Stop control to it.
- Corrected Claude's source-generated MCP guidance to tell the model to treat
  the callable inventory as authoritative, prefer direct single-fact calls,
  and use discovery only when that primitive is callable.
- Added turn-scoped provider-reported Codex model attribution with exact
  warm-configuration proofs, ordered settings/reroute handling, and a bounded
  per-thread observation cache.
- Added the structural root-agent row with root-only usage/tool/duration
  projection, requested-versus-reported model badges, and a dedicated
  owner-routed root Stop action that leaves delegates running.
- Added actionable Claude credential-probe recovery: the captured
  `credential_unknown` / `status_unavailable` card remains retryable without
  disconnecting the account and now also offers a forced **Reconnect** action.
- Coalesced Codex skill-catalog maintenance behind an idle gate. Startup,
  workspace, provider-invalidation, and plugin signals cannot start a new
  `skills/list` request while a root turn is active.
- Rebuilt and exercised the development app: root-only statistics, reported
  Codex model, road-sign Stop presentation and action, and the exact persisted
  Claude reconnect card were verified in the running UI.

In progress on 2026-07-30:

- The first history-reduction visibility slice publishes a content-free `history_reduced` event
  only after a reduced prompt enters the fresh Claude session, persists omitted/shortened counts,
  and gives it a distinct marker in the Activity Trace event rail. This is the terminal success
  projection, not yet the full started/completed/failed rollover/history-replay lifecycles,
  root-lane interval, or Usage context-chart marker this plan requires.

Not yet live:

- No shared proactive-context-maintenance controller is present in the release candidate.
  Codex has no production controller; Claude has a pre-send usage guard and bounded failure
  recovery, but it does not yet enforce the 88% projected gate when the reported native
  auto-compaction threshold is later.
- The Swift coordinator, full persisted context-maintenance lifecycle, operation-folding Activity
  row, timeout/retry UI, and latency telemetry remain to be implemented.
- The MCP source correction still needs an end-to-end exposed-inventory
  contract test, the large-result guard from E3, and rebuild/relaunch
  verification.
- A `skills/list` request that started while idle cannot yet be cancelled if a
  turn begins before it returns; eliminating that remaining startup race is
  still part of the first-response work.
- Provider-reported model attribution remains partial: Claude and OpenAI root
  reporting, Codex child metadata lookup, child provider identity, and an
  explicit "Model not reported" state remain to be implemented.
- Root native-tool accounting still needs the complete C2 protocol audit, and
  the card label should say "observed tools" rather than "tool calls."
- Narrow-width visual inspection and a real interactive Claude login round trip
  remain manual release checks; the normal-width rebuilt-app presentation and
  forced reconnect action policy have been verified.

## Provider-neutral context-maintenance amendment

The proactive-compaction portions of Workstream A now define one product policy with distinct
provider adapters. Codex remains the motivating cold-prefill case and retains its explicit App
Server lifecycle below. Claude is equally in scope through its Agent SDK context controls and
existing safe fresh-session recovery. An implementation that ships only the Codex adapter does not
satisfy this plan.

The shared initial policy remains:

```text
idleContextRatio                  0.82
idleDelay                         5 seconds
preSendProjectedRatio             0.88
minimumCompletionReserve          24,000 tokens
proportionalCompletionReserve     10% of context window
```

The shared layer owns authoritative context identity, the projected-context calculation, attempt
deduplication, cross-window ownership, at-most-once side-effecting prompt execution, content-free
telemetry, and provider-neutral maintenance activity. Each adapter owns its real provider
operation:

- **Codex subscription:** serialize App Server `thread/compact/start` against `turn/start` and
  reconcile the provider-created compaction item and turn.
- **Claude subscription and supported Anthropic/Vertex/Bedrock routes:** enable auto-compaction and
  precomputation at session creation; set the launch-time
  `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE` where that model/route honors proactive compaction; verify its
  read-only effective threshold through `getContextUsage()`; and use one bounded fresh-session
  rollover when early native compaction cannot be guaranteed safely. In-session
  `applyFlagSettings` may enable the two flags, but it is not a threshold-control API.

Native compaction, context rollover, and bounded history replay are different outcomes. Native
compaction preserves a provider-authored continuation summary inside the same session. Rollover
retires an opaque provider session and replays eligible durable history around the exact current
prompt. Bounded history replay starts without a source provider session and may make the same
content reduction without retiring one. UI, persistence, diagnostics, and tests must name the
outcome truthfully.

No threshold can make one enormous indivisible input compactable. This plan therefore also requires a
large-input/result guard for Mechanician-controlled attachments, MCP results, and tool adapters:
one payload must be chunked, excerpted, externalized durably, or rejected before it consumes the
maintenance reserve or immediately refills a compacted session. Full content must remain available
through an explicit, auditable path when the task genuinely needs it. Provider-owned built-in tool
results that Mechanician cannot intercept instead require advertised provider limits,
post-result usage observation, and maintenance before the next Mechanician-controlled send.

## Evidence and current behavior

### The slow turn was provider prefill, not app startup

The captured slow turn had this sequence:

| Phase | Elapsed |
| --- | ---: |
| Provider ready | about 3 ms |
| `turn/start` accepted | about 9 ms |
| First text | 69.2 s |
| Context compaction started | after first output |
| Compaction duration | 19.9 s |

The first model request contained 242,372 input tokens, had zero cached input
tokens, and occupied about 93.9% of the effective context window. The preceding
turn had reported 220,607 context tokens of a 258,400-token window. That prior
request was mostly cached, but the conversation then sat idle for about 93
minutes and the next request received no cache credit.

After Codex compacted the thread, reported context fell to 7,656 tokens. The
next request began reasoning in about 2.2 seconds. This is strong evidence that
the one-minute delay was the cold prefill of a nearly full thread.

Mechanician's existing Codex `prewarm` path resumes the thread with
`excludeTurns: true`. It gets the provider process and session ready, but it
does not prefill the resumed thread's full history. Upstream Codex also performs
a startup prewarm with an empty history. Neither mechanism can warm a
242,000-token prefix.

The bundled Codex version is 0.144.6. In that version, the turn path explicitly
notes that pre-turn compaction should account for incoming items, but the check
still occurs late enough that this request narrowly avoided pre-turn
compaction. The next tool result crossed the provider threshold, so compaction
occurred only after the user had already waited.

Relevant upstream references:

- [Codex turn pre-compaction TODO](https://github.com/openai/codex/blob/rust-v0.144.6/codex-rs/core/src/session/turn.rs#L152-L156)
- [Codex startup prewarm uses empty history](https://github.com/openai/codex/blob/rust-v0.144.6/codex-rs/core/src/session_startup_prewarm.rs#L241-L324)
- [Codex App Server thread compaction](https://learn.chatgpt.com/docs/app-server#trigger-thread-compaction)
- [OpenAI prompt caching](https://developers.openai.com/api/docs/guides/prompt-caching)

### Claude exposed the same policy gap through a different provider contract

Claude's current guard already reads the SDK's authoritative context usage, estimates the exact
incoming prompt conservatively, and reserves `max(24,000, 10% of the window)` for completion. It
computes `shouldCompact` at 88% projected usage, but when auto-compaction is enabled and Claude's
reported native threshold is later, that result can still resolve to `proceed`. Precomputation is
enabled in the query options, but precomputing a summary is not the same as applying it early.

When native compaction then fails, Mechanician correctly aborts before the provider can submit the
unchanged oversized request. If no model, tool, hook, delivered guidance, or other side effect was
observed, it retires the old SDK session and retries once with the exact current prompt plus a
bounded suffix of the durable transcript. A field report from a managed deployment showed that this recovery path
was invoked and the turn continued, but also exposed its cost: the new session may omit old detail,
loses opaque provider cache/session state, and cannot recover raw tool-only history.

Anthropic documents both parts of the preventive policy: auto-compaction can be configured to
trigger earlier, and compaction itself can fail when it starts without enough free room to produce
the summary. It also documents the structural case this policy cannot solve alone: one very large
file or tool result can immediately refill a compacted context.

- [Claude Code auto-compaction thresholds](https://code.claude.com/docs/en/env-vars)
- [Claude Code compaction failures](https://code.claude.com/docs/en/errors#error-during-compaction-conversation-too-long)
- [Claude Code context behavior and large-result limits](https://code.claude.com/docs/en/how-claude-code-works#when-context-fills-up)

### What the mature harnesses optimize

Codex and Claude Code use the same broad set of techniques:

- Keep the static prompt and tool prefix stable so exact-prefix caching can be
  reused.
- Start provider processes and restore session metadata before the user sends.
- Compact before another large turn crosses the context boundary.
- Avoid eagerly placing every optional tool schema in the hot prefix.
- Treat a very large cold resume differently from a warm continuation.
- Expose compaction as a first-class lifecycle event rather than an unexplained
  pause.

Claude Code additionally documents a cache-first prompt layout, a one-hour
subscription cache duration, cache-aware compaction, lazy MCP tool discovery,
and a choice between resuming a large cold session from a summary or from full
history:

- [Claude Code prompt caching](https://code.claude.com/docs/en/prompt-caching)
- [Claude Code session resume](https://code.claude.com/docs/en/sessions#resume-from-a-summary)
- [Claude Code MCP tool search](https://code.claude.com/docs/en/mcp#scale-with-mcp-tool-search)

Mechanician should adopt the policy and lifecycle pieces it controls. It should
not send a fake warm-up turn: that would spend tokens, mutate history, and still
not guarantee that the real request receives cache credit.

### Model names exist, but coverage is uneven

The agent-card presentation already renders `SubagentRun.model` and
`WorkflowAgent.model` when those fields are populated. The visible `Codex`
badge is the agent/provider type, not the model.

Current coverage:

- Root turns always have a requested model selection, but the requested model is
  not guaranteed to be the provider's effective model after a reroute.
- Claude child assistant frames normally include their provider-reported model, and
  Mechanician forwards it.
- Codex recognizes child `thread/settings/updated` and `model/rerouted`
  notifications, but the initial child lifecycle often supplies neither. In
  recent captured sessions, every Codex child card had `model: null`, even
  though its provider rollout recorded `gpt-5.6-sol`.
- Codex `thread/start` and `thread/resume` responses contain a model, but
  Mechanician currently discards it for root turns.
- Direct OpenAI responses contain `response.model`, which is also currently
  discarded.

The implementation must distinguish a requested model from a
provider-reported effective model. “Effective” here means the identity reported
by the provider protocol; it does not claim knowledge of private backend
weights. Mechanician must not copy the root's requested model onto child
agents.

### Root data exists, but the card projection does not

The pinned “This conversation” card is a whole-turn aggregate across the root
and delegated agents. It should remain a rollup.

Root activity is already recorded under `AgentActivityIdentity.root`, including
root usage and most foreground tools. The Activity chart already displays a
root lane. The missing piece is a root-only projection for the selected active
turn, otherwise the latest turn, plus a structural row in the Agents table.

The table's existing activity index spans the retained conversation ledger.
Using it directly would accumulate root tokens and tools across multiple turns.
The root card must derive from the selected-turn records already owned by
`AgentConversationActivityIndex`.

## Product decisions and invariants

1. **Context maintenance is not a hidden turn.** Native compaction, bounded rollover, and any
   bounded replay that reduces provider-visible history get immediate Activity lines with started,
   completed, and failed states, and remain visibly distinct.
2. **At most one side-effecting provider execution may receive the prompt.** Codex sends zero or one
   `turn/start`. Claude's inline compaction path may enqueue the exact prompt once in the old SDK
   stream and once in a fresh stream only after authoritative evidence that the old stream produced
   no model, tool, task, hook, delivered guidance, or other side effect. Starting a competing
   provider turn after work begins is not allowed.
3. **Scheduled maintenance may be cancelled; accepted native maintenance may not.** A rapid
   follow-up cancels the idle timer and is evaluated by the send-time gate.
4. **Maintenance never resurrects a terminal root state.** Its Activity
   lifecycle is separate from the root turn lifecycle.
5. **The conversation summary remains aggregate-wide.** The new root card is
   root-only and selected-turn-only.
6. **Provider, role/type, and model are separate attribution.** Cards prefer an
   effective model reported by the provider. Missing data is explicit; it is
   never inferred from a parent.
7. **Root duration stops when the root terminates.** Child tail time remains
   visible in the conversation summary but is not charged to the root card.
8. **Root tool counts are labeled “observed tools.”** Codex does not expose one
   authoritative root tool-call aggregate, so Mechanician must not imply that
   its coverage is stronger than it is.
9. **Only the owning bridge may schedule maintenance.** Opening the same
   conversation in another window must not cause duplicate operations.
10. **No content enters performance diagnostics.** Prompts, outputs, tool
    arguments/results, credentials, and environment values remain excluded.
11. **The decision is shared; the provider operation is not.** Codex explicit compaction, Claude
    native auto-compaction, bounded rollover, and bounded history replay keep their real contracts
    and failure semantics.
12. **History reduction is never labeled as compaction.** Rollover and bounded replay remain
    durable, visible maintenance outcomes, but only a real provider summary produces a compaction
    boundary.
13. **The 88% projected gate is operational.** A later provider threshold cannot turn
    `shouldCompact` into permission to proceed without verified maintenance or safe rollover.
14. **Single-turn spikes have a separate budget.** Maintenance policy does not excuse admitting one
    input or result that consumes the reserved working room by itself.

## Target architecture

```text
Conversation context snapshot
  provider, tokens, window, model, provider session, sampledAt
                │
                ▼
Swift ContextMaintenanceCoordinator
  owner check, idle scheduling, persistence, UI route
                │
                ▼
agentd shared policy + provider adapter registry
  thresholds, reserve, single flight, final send gate
             ┌──┴─────────────────────┐
             ▼                        ▼
Codex adapter                  Claude adapter
explicit compact/start         arm native auto-compaction
and lifecycle reconcile        verify usage/threshold
                               or roll to bounded fresh session
             └──────────┬─────────────┘
                        ▼
provider-neutral maintenance events
  Activity line + persisted attempt + at-most-one side-effecting execution
```

The numeric policy belongs in shared agentd code. Each adapter owns its provider's
irreversible-send boundary and native lifecycle: Codex serializes `thread/compact/start` with
`turn/start`; Claude supplies launch-time compaction policy, verifies the SDK's effective read-only
threshold, observes the SDK compaction lifecycle, and rolls to a bounded fresh session when early
compaction cannot be guaranteed. Swift owns scheduling, cross-window ownership, persistence, and
presentation.

## Workstream A: initial-response performance and context reliability

### A1. Add phase-level latency telemetry

Implement this first so every subsequent change can be measured.

Add allowlisted timestamps and counters for:

- prompt accepted by the Swift bridge;
- provider prewarm scheduled, started, and completed;
- provider process ready;
- provider session/thread resume started and completed;
- context maintenance evaluated, scheduled, started, completed, failed, or joined, including the
  selected native-preparation, native-compaction, or rollover operation;
- provider prompt/request delivery sent and acknowledged;
- first provider event;
- first reasoning delta;
- first text delta;
- terminal event;
- input, cached-input, and output tokens;
- last context tokens, context window, context ratio, model, and sample age; and
- the projected-context decision and the policy reason code.

Use monotonic time for durations and wall-clock time only for correlation.
Record a bounded enum for decision reasons:

```text
provider_unsupported
no_provider_session
no_context_sample
model_mismatch
already_maintained
failed_same_sample
below_threshold
active_work
scheduled
started
joined_existing
native_preparation_prepared
native_compaction_completed
threshold_too_late
fresh_rollover
rollover_completed
post_maintenance_too_large
side_effect_free_replay
replay_forbidden
cancelled
failed_prompt_retained
```

Add these fields to the existing redacted lifecycle diagnostics allowlist. Log
counts and ratios, not prompt text or tool payloads. Diagnostics use bounded hashes for provider
session correlation; raw opaque session IDs remain only in local operation/persistence state.

Primary files:

- `agentd/src/agentd.mjs`
- a new `agentd/src/context-maintenance-policy.mjs`
- Codex and Claude provider-adapter modules
- `agentd/src/claude-context-guard.mjs`
- `app/Sources/Mechanician/AgentBridge.swift`
- the existing lifecycle diagnostics exporter and its tests

Acceptance:

- A trace can separate app startup, session restore, provider prefill, native compaction, bounded
  rollover, reasoning, and output delay.
- A request above 100,000 input tokens with zero cached tokens is identifiable
  without inspecting conversation content.
- Existing diagnostics privacy tests remain green.

### A2. Persist an authoritative context snapshot

Replace the three loosely related context fields with a compatible optional
snapshot while continuing to decode old sidecars:

```swift
struct ProviderContextSnapshot: Codable, Equatable {
    var sampleID: UUID
    var providerAccess: ModelAccess
    var tokens: Int
    var window: Int
    var modelID: String
    var providerSessionID: String
    var sampledAt: Date
}

struct ContextMaintenanceRecord: Codable, Equatable {
    var operationID: UUID
    var providerAccess: ModelAccess
    var sourceProviderSessionID: String?
    var destinationProviderSessionID: String?
    var providerGeneration: String
    var sourceSampleID: UUID?
    var trigger: Trigger       // idle, resume, preSend, provider
    var operation: Operation   // nativePreparation, nativeCompaction,
                               // boundedRollover, boundedHistoryReplay
    var reductionReason: HistoryReductionReason?
    var effectiveThreshold: Int?
    var startedAt: Date
    var finishedAt: Date?
    var outcome: Outcome?      // nil while active; prepared, completed, failed, cancelled
    var preTokens: Int?
    var postTokens: Int?
    var omittedMessages: Int?
    var shortenedMessages: Int?
}
```

The existing `contextTokens`, `contextWindow`, and `contextModel` keys and
accessors must remain compatible while the snapshot becomes the canonical
persisted value. Legacy Codex fields may synthesize a snapshot only when a matching Codex session
exists. The generated sample ID must then be persisted so it does not change on every decode. New
optional keys must use tolerant decoding.

For Codex, `providerSessionID` is the root `Thread.id`, never the shared `Thread.sessionId`. For
Claude, it is the opaque SDK `session_id`, never the local conversation ID. Codex joins
`thread/tokenUsage/updated` to its turn-scoped model observation; Claude uses normalized
`getContextUsage()`. Both reject stale model, session, access-route, or process-generation
observations.

For native compaction, source and destination session IDs are identical. Native preparation has a
source and no destination. A rollover captures the retired opaque session as source and the newly
initialized session as destination; its completion remains authorized by `operationID` even though
ordinary stale-source events are rejected. A bounded history replay that starts in an already-fresh
session has no retired source and records only its destination. The allowlisted reduction reason
distinguishes `context_compaction_failed`, `provider_session_expired`, `durable_history_replay`, and
other approved recovery causes without persisting raw provider text.

Update a snapshot only from authoritative root-provider usage for the matching provider session and
model. Clear it when:

- the provider access changes;
- the provider session/thread identity changes;
- the user changes model;
- the conversation is reset or forked onto a new session; or
- a stale provider generation attempts to update it.

The record marks a particular sample as already attempted. A completed record
consumes that sample. A failed record suppresses automatic retry against the
same sample until a newer context sample, an explicit user action, or a
provider restart permits one new attempt. This prevents reopen/relaunch loops
when the provider does not immediately report post-maintenance token usage or
continues rejecting maintenance. A `nativePreparation/prepared` record is keyed by source sample,
provider generation, and verified effective threshold. It suppresses another idle arm for that
same tuple without claiming the sample was compacted; a newer sample, provider generation, or
effective threshold may prepare again.

`sourceSampleID` is absent for provider-initiated maintenance that cannot be correlated to a stored
pre-maintenance sample and for a bounded history replay that begins without a valid provider-session
snapshot. Rollover/replay omission and shortening counts are content-free facts about the replay
decision; they never contain transcript text.

Primary files:

- `app/Sources/Mechanician/AgentBridge.swift`
- `app/Sources/Mechanician/ConversationStore.swift`
- conversation persistence and legacy-sidecar tests

Acceptance:

- Relaunch preserves enough information to evaluate a cold resume.
- An attempt record never suppresses maintenance after a newer context sample.
- A rollover completion names both the retired and replacement provider sessions and cannot be
  rejected as a stale event from the retired session.
- A fresh bounded replay with no retired provider session remains a history-reduction operation and
  never fabricates a rollover source.
- A prepared sample does not re-arm on every idle debounce or masquerade as completed compaction.
- A sample from one model, session, or process generation cannot affect
  another.

### A3. Implement one pure context-maintenance policy

Put the maintenance decision in
`agentd/src/context-maintenance-policy.mjs` and unit-test it without a live
provider.

Swift supplies the trigger, persisted snapshot/attempt record, and its
conversation work-state facts. It may decide when to ask, but it must not
duplicate the numeric threshold logic. agentd combines those facts with authoritative
provider-session state and capability evidence, then returns the final decision. Provider adapters
decide how to fulfill that decision without changing its thresholds.

Initial feature-flagged defaults:

```text
idleContextRatio                  0.82
idleDelay                         5 seconds
preSendProjectedRatio             0.88
minimumCompletionReserve          24,000 tokens
proportionalCompletionReserve     10% of context window
```

The projected context is:

```text
current context
+ conservative incoming-message estimate
+ documented reserves for non-text inputs
+ max(24,000, 10% of context window)
```

For a native threshold expressed in input tokens, the latest acceptable trigger is:

```text
max(0, floor(context window × 0.88) - max(24,000, 10% of context window))
```

Until a provider tokenizer is available, estimate incoming text as
`ceil(UTF-8 bytes / 3)` and add a fixed, documented reserve for each non-text
input. The completion reserve intentionally covers reasoning and an early large
tool result. Keep all constants in one policy object so measured data can tune
them without changing routing code. Choose the latest provider threshold that satisfies this bound;
compacting more aggressively than necessary would discard useful verbatim context and cache sooner.
The defaults and algorithm are shared. Any provider/model override is explicit, versioned in the
central policy, and justified by per-provider quality/latency evidence; adapters never hardcode a
different formula.

The shared policy decides whether maintenance is required; adapters decide how. Codex may compact
explicitly. Claude must arm native auto-compaction and precomputation at session creation,
supply launch-time threshold policy no later than the bound above, and verify the result through
`getContextUsage()`. For Claude's integer percentage control:

```text
thresholdReferenceWindow =
  min(authoritative context window,
      advertised auto-compaction window when known)

targetPercent =
  floor(100 × latest acceptable input threshold / thresholdReferenceWindow)
```

When the reference window is already no larger than the acceptable trigger, leave the provider's
earlier default alone and verify it. Otherwise supply a valid `1...100` value as
`CLAUDE_AUTOCOMPACT_PCT_OVERRIDE` in the SDK child/query environment before initialization,
rounding down so the effective token threshold cannot move later than the safety bound. Preserve an
existing valid lower value and never use this policy to delay a user/managed earlier threshold. The
variable can only lower the provider default and only affects models/routes where Claude performs
proactive compaction. `autoCompactThreshold` from `getContextUsage()` is read-only provider truth.
`applyFlagSettings` may enable `autoCompactEnabled` and `precomputeCompactionEnabled`; it cannot
change that threshold. An invalid percentage, a route that ignores the override, or a
managed/default threshold that remains too late is not proof of safety.

For Claude, the read-back threshold is sufficient pre-send proof only when the input that the
provider will use to trigger native compaction reaches it:

```text
nativeTriggerInput =
  current provider input tokens
  + incoming provider input tokens
```

Use exact/provider-tokenized incoming input when available. Otherwise use an adapter-specific,
route-validated trigger estimate that includes provider-counted non-text input; uncertainty fails
closed to bounded rollover. The shared completion reserve and any policy-only reserve can make
`shouldCompact` true, but they do not count toward `nativeTriggerInput` and cannot prove that Claude
will compact. If `nativeTriggerInput < autoCompactThreshold`, native compaction is not guaranteed
for this send and the adapter must roll over before side-effecting work.

The adapter registry is capability-based, not a provider-name shortcut. Each route advertises the
authoritative support it actually has:

```text
authoritativeContextUsage
explicitNativeCompaction
idlePreparation
nativeAutoCompaction
launchThresholdControl
nativeLifecycleEvents
safeBoundedRollover
```

The shared layer never infers that one provider supports another provider's operation. A later
provider can participate by implementing the relevant capabilities without changing the numeric
policy or the Activity contract.

Idle evaluation is eligible when:

- the selected provider adapter supports authoritative context usage plus either explicit native
  compaction or non-destructive idle preparation;
- a resumable provider session exists;
- snapshot access route, session, and model match;
- the snapshot has not already been consumed/suppressed by its latest
  maintenance attempt record;
- `tokens / window >= 0.82`;
- root and all delegated agents are terminal;
- no prompt is queued, steering, or awaiting delivery;
- no approval or user-input request is outstanding; and
- this provider session has no scheduled or active maintenance.

Bounded rollover is never idle-eligible: it is a lossy recovery that requires the exact current
prompt, an explicit pre-send decision, and visible omission accounting. A rollover-only route waits
for the pre-send gate.

The five-second debounce gives a rapid follow-up a chance to cancel scheduled
maintenance. The send-time gate then evaluates that prompt atomically.

Pre-send evaluation is eligible when:

- provider, session, snapshot, model, generation, and attempt-record identity
  checks pass;
- the provider parent session has no previously accepted active root turn; the
  incoming local queued turn does not disqualify its own preflight;
- existing conversation queuing/child barriers have allowed this turn to
  advance to provider preflight; and
- projected context is at least 88% of the window.

An old snapshot remains a valid conservative hint if its provider session and
model still match. Age is recorded for diagnostics but does not, by itself,
invalidate an otherwise unchanged provider session. This is required to repair the
93-minute cold-resume case.

If no fresh usage exists, a matching persisted snapshot remains a conservative signal. If neither
exists, proceed only when the adapter has no authoritative usage capability. Failure of a promised
control surface requires bounded recovery rather than treating “unknown” as “fits.”

Policy tests:

- the observed 220,607 / 258,400 case requires provider-appropriate maintenance;
- a small fresh session does not;
- a large incoming prompt can cross the projected gate;
- a consumed sample does not run maintenance twice;
- a newer sample is eligible again;
- model, session, and generation mismatch reject;
- active root, child, approval, input wait, or queued prompt reject idle work;
- a prompt arriving during the debounce cancels idle scheduling;
- a prompt arriving during active maintenance joins it;
- a rollover-only adapter never invalidates a provider session while idle;
- an armed/prepared result suppresses repeated idle preparation for the same sample, threshold, and
  provider generation;
- boundary values at 82% and 88% are deterministic;
- identical inputs produce the same shared decision for Claude and Codex;
- Claude `shouldCompact=true` with `nativeTriggerInput` below the read-back native threshold never
  resolves to `proceed`, including when only completion or policy-only reserve crossed 88%; and
- a stale, ignored, timed-out, or managed Claude threshold yields safe rollover before prompt
  delivery.

### A4. Add the Codex explicit-compaction adapter

Add a provider-specific controller keyed by Codex thread ID behind the shared policy:

```text
codexCompactionsByThread:
  threadId -> {
    requestId,
    trigger,
    state,
    startedAt,
    sourceSnapshot,
    waiters,
    processGeneration
  }
```

Expose one internal operation:

```text
requestCodexCompaction(threadId, snapshot, trigger, route)
  -> joined | completed | failed
```

Behavior:

1. Validate the process generation, login mode, thread identity, and policy.
2. Return the existing promise when the thread already has an active
   compaction.
3. Resume/load the thread if needed without including turns.
4. Confirm that the provider thread is idle.
5. Capture the pre-request turn/item identity set and register maintenance
   ownership by provider thread before sending the provider request.
6. Call `thread/compact/start`.
7. Treat its empty JSON-RPC response as acceptance only; lifecycle
   notifications may arrive before the response is consumed.
8. Bind the first new `contextCompaction` item to its notification-provided
   turn ID and item ID.
9. Resolve every waiter exactly once from the matching
   `turn/completed.status` and optional turn error. `item/completed` alone does
   not prove success.
10. Remove the single-flight entry only after terminal bookkeeping finishes.

`thread/compact/start` has an empty response body and no provider turn/item
identity. Do not treat its response as completion. Use the provider item/turn
lifecycle; if a notification is missed, diff the pre-request identities against
`thread/read(includeTurns: true)`. When a returned turn has summary/not-loaded
items, call `thread/items/list` for that turn before inferring that the
compaction is absent.

Do not use the ordinary active-turn map for idle maintenance. That map is
deleted when a root turn finishes, and compaction may create provider turn/item
IDs of its own. Add an explicit maintenance route keyed by thread plus
provider-created identities so notifications cannot be dropped or mistaken for
early child activity.

Before coding against the method, regenerate or inspect the pinned 0.144.6
schema and pin the exact request, response, item, and notification fields in
`agentd/scripts/verify-codex-schema.mjs`.

Failure behavior:

- Idle or resume maintenance records a failure and leaves the conversation
  usable.
- Pre-send maintenance records a visible failure and revalidates authoritative usage. The prompt
  proceeds once only when it still fits with the policy reserve. Otherwise Codex stops before
  `turn/start`, retains the exact queued prompt, and offers the existing retry/new-conversation
  recovery. It must not strand, truncate, silently discard, or silently roll over the user's
  prompt. If a future Codex route explicitly gains safe bounded rollover, it uses the same
  provider-neutral rollover lifecycle rather than being inferred from provider identity.
- Authentication, approval, or process-generation failures use existing
  provider recovery paths.
- A timeout triggers authoritative reconciliation, not a blind provider kill.

### A4b. Add the Claude native-compaction, rollover, and replay adapter

Before Claude query/session initialization, derive the integer percentage against the authoritative
context window (or a smaller advertised auto-compaction window), preserve any valid earlier
user/managed value, supply `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE` in that SDK child's environment, and
include the launch policy in the warm-query identity so a spare created with a later threshold
cannot be reused. Request both `autoCompactEnabled` and `precomputeCompactionEnabled` at creation.
Treat all launch/settings values only as intent: re-read `getContextUsage()` and use its effective
`isAutoCompactEnabled` and read-only `autoCompactThreshold` as provider truth. If the window needed
for percentage conversion was unknown before launch, an initialized-but-unused child may be closed
and relaunched once with the newly learned value; no prompt or hook may have entered it.

Idle preparation verifies the launch-time threshold and permits native precomputation. It never
sends a synthetic prompt or claims that compaction has completed; it persists
`nativePreparation/prepared` for the sample, provider generation, and threshold. At the pre-send
gate, `shouldCompact` may not resolve to `proceed` merely because the SDK's reported native
threshold is later. `applyFlagSettings` may enable the two compaction flags and be re-read, but it
cannot repair a late threshold in the already-running child. Immediately before enqueue, require
`current provider input + exact/provider-tokenized incoming provider input` (or a route-validated
trigger estimate) to reach the read-back `autoCompactThreshold`; the completion reserve is excluded
from that proof. When the effective launch-time threshold remains too late, the actual incoming
provider input cannot be shown to cross it, or the route does not honor proactive compaction,
invalidate the opaque session and start one bounded fresh session before side-effecting model work.

Observe the existing SDK lifecycle:

```text
status: compacting
compact_result: success | failed
compact_boundary
```

Abort a failed native compact before provider fallthrough. The exact prompt may be enqueued into a
fresh SDK stream once only when the old stream proves that no model output, tool/task/hook activity,
delivered guidance, interruption, or unknown side-effect-capable SDK event occurred. This is two
transport enqueues in the failure case but at most one side-effecting execution. A repeated failure
in the fresh bounded session is terminal; it never enters a retry loop.

Emit `context_rollover_started` before invalidating the opaque session, then complete or fail that
same operation after the bounded replay result is known. Completion means the exact current prompt
and bounded replay were successfully enqueued into the fresh SDK session; later model response time
belongs to the root turn, not the rollover span. Completion records retired and destination session
IDs, the allowlisted reduction reason, omitted/shortened counts, and the newly reported context size
when available. It does not emit `compact_boundary`, because no provider-authored summary was
created.

If bounded replay begins without a resumable provider session and omits or shortens history, emit
the parallel `context_history_replay_*` lifecycle with no source session rather than pretending that
a rollover retired one. Its completion still records the destination, reduction reason,
exact-prompt preservation, and omitted/shortened counts. When the complete eligible durable replay
fits and no provider session was retired, retain diagnostics but emit no user-facing
history-reduction lifecycle.

When the provider reports content-free usage categories, the adapter preserves them as signals for
the large-result guard. A single current prompt that does not fit a fresh session is rejected
intact with Edit Prompt recovery. Mechanician-controlled tool/attachment results must be bounded or
externalized before they enter provider context; provider-owned built-in results rely on advertised
provider limits and post-result usage recovery before the next Mechanician-controlled send. Proactive
summarization cannot repair an indivisible result after the fact.

### A5. Put the final gate immediately before each provider's irreversible-send boundary

Extend the run/prewarm request with the optional context snapshot and latest
maintenance attempt record.

For Codex, in `runCodex` after the provider thread is started/resumed but immediately before
`turn/start`:

1. Evaluate the shared policy with the actual incoming prompt.
2. Cancel an unstarted idle timer for that thread.
3. Join an active compaction, or start one when the projected gate is crossed.
4. Emit a maintenance start event immediately.
5. Wait for authoritative compaction completion.
6. Revalidate process generation and thread ownership.
7. Obtain or reconcile authoritative post-compaction usage and recompute the shared gate with the
   unchanged prompt. If authoritative usage is unavailable, require the adapter's documented
   conservative fit proof; never treat unknown post-tokens as zero.
8. Send one `turn/start` only when the post-maintenance gate passes; otherwise retain the prompt and
   send zero.

This ordering closes the race between an app-side check and provider
`turn/start`. The prompt stays associated with its already-created client turn,
so Stop can cancel prompt delivery while it waits. Stop does not attempt to
undo a compaction that the provider has already started.

Add fake App Server integration tests that prove the exact call order:

```text
thread/resume
thread/compact/start
contextCompaction completed
post-compaction usage/final fit gate
turn/start
```

Also test:

- completion before the compact-start response is consumed;
- duplicated and reordered item notifications;
- a missing completion recovered through `thread/read`;
- provider restart during compaction;
- two windows requesting maintenance for the same thread;
- an idle request and prompt racing each other;
- Stop while a prompt is waiting;
- maintenance failure followed by one `turn/start` when authoritative recheck fits;
- maintenance success or failure followed by zero `turn/start` when the unchanged prompt still
  does not fit;
- a successful summary that remains too large for an indivisible prompt; and
- no second `turn/start` after late notifications.

Add fake Claude SDK integration tests that prove both exact paths:

```text
Claude native path:
launch child with allowlisted threshold environment
query/resume initialized
getContextUsage
apply/verify enablement flags when needed
verify nativeTriggerInput reaches read-back autoCompactThreshold
prompt enters the SDK stream exactly once
compacting status
compact boundary
model request/response

Claude pre-send rollover path:
launch child with allowlisted threshold environment
query/resume initialized
getContextUsage
effective threshold remains too late or nativeTriggerInput remains below it
old session invalidated before prompt delivery
fresh bounded query created
newest eligible history + exact current prompt delivered once

Claude failed-inline-compaction recovery:
exact prompt enters old SDK stream
compaction fails before any model/tool/task/hook/guidance work
old session invalidated
exact prompt + bounded replay enter fresh SDK stream once
only the fresh stream performs side-effecting provider/model work
```

Stop may cancel waiting prompt delivery on either provider. It does not cancel or misreport native
maintenance that the provider has already accepted.

### A6. Add the Swift maintenance coordinator

Add a process-wide, main-actor `ContextMaintenanceCoordinator`.

Responsibilities:

- schedule the five-second idle debounce after a selected turn and all children
  become terminal;
- evaluate persisted high-context conversations on restore/prewarm;
- cancel scheduled work on prompt delivery, model/session change, ownership
  change, or conversation deletion;
- use `AgentBridge.owner(of:)` / `activeOwner(of:)` so only the owning bridge
  acts;
- register a provider-scoped maintenance route before sending an adapter operation;
- persist preparation/attempt records, post-maintenance usage, optional source and destination
  session identities for rollover/replay, the allowlisted reduction reason, and
  omission/shortening counts;
- expose live operation state to the Activity panel; and
- reject events from a stale bridge, conversation generation, or provider
  generation.

Suggested provider-neutral control envelope:

```json
{
  "type": "context_maintenance",
  "id": "maintenance-request-id",
  "provider": "codex | anthropic",
  "sourceProviderSessionId": "provider-root-thread-or-sdk-session-id",
  "convId": "conversation-id",
  "requestedAction": "prepare | compact | evaluate | rollover | replay",
  "trigger": "idle | resume | preSend",
  "workState": {
    "rootActive": false,
    "delegateActive": false,
    "queuedPrompt": false,
    "awaitingApprovalOrInput": false
  },
  "contextSnapshot": {
    "sampleId": "context-sample-id",
    "tokens": 220607,
    "window": 258400,
    "model": "gpt-5.6-sol",
    "sampledAt": "..."
  }
}
```

`sourceProviderSessionId` is optional/nullable for bounded history replay that begins without a
provider session.

The coordinator routes this envelope to the Codex or Claude adapter; it does not pretend their wire
operations are symmetric. A `prepared` Claude result persists the verified sample/threshold/provider
generation so idle evaluation does not repeat, but it does not consume the source sample as though
a native compaction completed.

Suggested provider-neutral events:

```text
context_preparation_started
context_preparation_completed
context_preparation_failed
context_compaction_started
context_compaction_completed
context_compaction_failed
context_rollover_started
context_rollover_completed
context_rollover_failed
context_history_replay_started
context_history_replay_completed
context_history_replay_failed
```

`context_preparation_*` events are persistence/diagnostics-only. They do not create an Activity
line, Trace mark, or Usage mark because preparation alone neither changes provider-visible history
nor delays an accepted prompt. The visible operation families are native compaction, bounded
rollover, and bounded history replay when that replay actually omits or shortens history.

During migration, the current `history_reduced` terminal event is a compatibility projection of
either `context_rollover_completed` or `context_history_replay_completed` when omitted or shortened
counts are positive. Classify it as rollover only when a linked lifecycle/attempt record proves
that a source provider session was retired; otherwise preserve the truthful generic history-replay
classification. The coordinator adds an optional operation ID to new `history_reduced` projections
and deduplicates them directly. For already-persisted projections without an operation ID, a
same-turn lifecycle completion with matching allowlisted reason/counts replaces the legacy
projection instead of drawing twice. Every true fresh-session rollover still gets the full
lifecycle, even when the complete durable replay fits, because retiring provider state/cache is
itself a meaningful maintenance outcome. A bounded replay that began without a provider session
gets the history-replay lifecycle only when it reduces history and never fabricates an old session.

Every event carries request ID, provider and conversation identity, optional source session
identity, trigger, process generation, operation kind, resolution, and timestamps. Rollover and
history-replay completion add destination session identity, allowlisted reduction reason,
content-free omitted/shortened-message counts, and whether the exact current prompt was preserved.
They complete when the fresh stream accepts the prompt, not when the model turn ends. Pre/post token
counts are nullable. Unknown counts must be `null`, never zero.

Restore/prewarm behavior:

- A large matching snapshot schedules explicit native compaction or non-destructive preparation as
  soon as its lane is ready. A rollover-only adapter waits for an exact prompt at the pre-send gate.
- A completed record for that exact sample suppresses repeat work; a failed
  record applies the bounded retry policy.
- A prepared record suppresses repeated idle arming only for its matching sample, threshold, and
  provider generation.
- Opening another window does not duplicate the operation.
- Maintenance alone does not mark the conversation unread.

### A7. Show compaction, rollover, and bounded history replay in Activity and the agent swimlanes

The Activity panel already understands compaction markers during a turn, but an
idle compaction occurs after the root has terminalized. Appending an ordinary
nonterminal root state would violate the terminal-monotonic reducer.

The released fresh-session bounded replay has a second visibility gap: it may invalidate an
existing provider session, then emits an informational transcript row but no `compact_boundary`, so
the agent swimlanes do not show where older provider-visible history was omitted or shortened. The
in-progress terminal `history_reduced` event adds the first successful Trace marker. Preserve that
downgrade-compatible projection while promoting it to a truthful rollover or bounded-history-replay
lifecycle according to whether an old provider session was actually retired; never manufacture a
compaction boundary for either operation.

Extend maintenance activity with optional operation metadata:

```text
operationId
operationKind: nativeCompaction | boundedRollover | boundedHistoryReplay
operationState: started | completed | failed
operationTrigger: idle | resume | preSend | provider
operationResolution: proceeded | freshSession | stopped
sourceProviderSessionId?
destinationProviderSessionId?
reductionReason?
operationStartedAt
operationEndedAt
preTokens?
postTokens?
replayedTokens?
omittedMessages?
shortenedMessages?
```

The presentation folds records with the same operation ID into one line:

```text
Compacting context…
Compacted context · 220.6k → 7.7k · 19.9s
Context compaction failed · prompt retained
Rolling context into a fresh session…
Context rolled over · 18 older messages omitted · current prompt preserved
Context rolled over · all eligible durable history replayed · current prompt preserved
Context rollover failed · prompt retained
Replaying bounded history…
History replay reduced · 18 older messages omitted · current prompt preserved
History replay failed · prompt retained
```

Rules:

- Insert the started line as soon as Mechanician decides to wait.
- Complete the same logical rollover or replay line when the fresh stream accepts the preserved
  prompt; later model/tool time stays on the root turn. If fresh enqueue fails, close it as failed
  with the prompt retained.
- Attach the operation to the source/selected turn for display, but do not
  change the root's terminal lifecycle.
- On success, append the existing transcript conversation-summary compaction
  entry only for native compaction.
- Append a distinct durable history-reduction entry when bounded rollover or replay omits or
  shortens history. It records the truthful operation kind, counts, and exact-prompt-preserved
  guarantee without embedding omitted content.
- In **Trace**, keep the terminal marker in the event rail and draw a known-duration rollover on the
  root agent's maintenance track; draw bounded history replay there as well. Compaction retains the
  existing purple hatched block. Rollover and replay use accessible non-compaction shapes/patterns
  and truthful labels such as **Context rollover** and **History replay**, with a minimum visible
  width for an instantaneous pre-send operation.
- In **Usage**, add the corresponding distinct rollover or history-replay marker to the root
  context-pressure chart beside, but not styled or counted as, its existing compaction markers.
- Tooltips and accessibility labels report trigger, provider, omitted/shortened counts, and
  before/after context when known. They say that an old provider session was retired only for a
  rollover with a real source session; replay without one uses neutral history-reduction copy.
  Neither operation increments the compaction count or adopts the compaction icon/name.
- Preserve completed maintenance across relaunch.
- Do not mark the conversation unread for maintenance alone.
- A pre-send prompt waiting behind maintenance remains visibly queued.

Tests:

- the line appears before the provider operation completes;
- start and completion fold into one logical operation;
- unknown token counts do not render as zero;
- compaction failure, rollover resolution, and bounded history replay remain visually distinct;
- a bounded fresh recovery creates the correct rollover or replay marker even though no
  `compact_boundary` arrived;
- a rollover that replays all durable history remains visible without being mislabeled as
  truncation;
- a no-source replay that fits all eligible durable history emits no history-reduction marker;
- the rollover span ends at fresh-stream prompt acceptance rather than absorbing model response
  time;
- a replay with no source provider session never claims that an old session was retired;
- source/destination session identities survive stale-session filtering without being exposed in
  ordinary UI copy;
- operation-ID projections deduplicate exactly, while a legacy same-turn `history_reduced` record
  without an operation ID remains one terminal marker and defaults to generic history replay unless
  linked state proves rollover;
- Trace places the event/interval on the correct root timeline, Usage places it on the root
  context-pressure chart, and both preserve it across conversation switching and relaunch;
- rollover/replay omitted/shortened counts and accessible descriptions match the bounded replay
  result;
- provider/session/model switches cannot attach the marker to the wrong lane;
- a terminal root stays terminal;
- selected-turn token and summary selection do not move to a fake maintenance
  turn; and
- persistence uses tolerant optional decoding.

### A8. Stabilize and shrink the cacheable prefix

This is P1 after proactive maintenance is working and measured.

Add a privacy-safe prefix inventory containing byte/token estimates and hashes
for:

- base provider instructions;
- workspace instructions;
- skill/plugin catalog;
- eager tool schemas;
- deferred tool schemas; and
- volatile per-turn metadata.

Then:

- make tool and instruction ordering deterministic;
- keep volatile timestamps, IDs, and status text out of stable prefix blocks;
- lazy-load optional MCP/plugin schemas through tool search;
- avoid serializing inactive capabilities into every request;
- preserve identical blocks byte-for-byte across turns; and
- compare cached-input ratios before and after each change.

Because each provider harness constructs parts of the final request, first confirm which portions
Mechanician can actually influence on Codex and Claude. Do not duplicate provider instructions
merely to create a locally stable block.

Acceptance:

- No functional capability disappears.
- Tool discovery remains available.
- The stable-prefix hash remains unchanged across equivalent turns.
- Cached-input ratio does not regress in warm continuation benchmarks.

### A9. Add a cold-resume path for very large sessions

This is P1 and should be considered only after automatic idle/resume
maintenance is reliable.

When a matching persisted snapshot is both:

- above 100,000 tokens; and
- older than the observed provider cache horizon,

Mechanician may surface a provider-appropriate choice:

- **Resume reduced** — use a provider-native summary when explicit compaction is supported;
  otherwise offer a clearly labeled bounded rollover only when that route can do so safely.
- **Resume full** — preserve full history and accept potentially slower prefill.

Automatic proactive maintenance remains the default for sessions above the policy threshold.
The choice is an escape hatch for users who value exact full history over latency; it is not shown
for ordinary conversations, and rollover is never presented as provider-native compaction.

## Workstream B: provider-reported model identity

### B1. Define turn-scoped provider, role, and model attribution

Do not put one effective model on the conversation. A later turn may use a
different model, and the selected historical turn must retain its own identity.

Add a durable provider-neutral attribution keyed by:

```text
turnID + agentID + provider process generation

providerAccess
agentRoleOrType?
requestedModelID?
providerReportedModelID?
observationSource
observationRevision
observedAt
```

`SubagentRun` and `WorkflowAgent` also need persisted provider access. Their
current type badge is an agent role/type and only coincidentally says `Codex` in
some paths. The card must be able to render provider, role/type, and model as
separate values, deduplicating identical adjacent badges.

Keep `Conversation.modelSelection` as the user's requested route and routing
preference. Do not rewrite the model picker after a provider reroute. Keep
conversation-wide fallback state such as `claudeEffectiveModel` out of
historical card attribution.

Cards use:

1. the provider-reported model when present;
2. the root requested model as a clearly identified requested value while
   provider confirmation is pending; and
3. `Model not reported` when a child provider never supplies a reported
   model.

Do not use the root's requested model as a child fallback.

The visual badge and accessibility text must distinguish
`gpt-5.6-sol (requested)` from a provider-confirmed `gpt-5.6-sol`.
`Model not reported` must not use confirmed-model styling.

Persist new optional attribution fields with tolerant decoding. Legacy children
may have neither provider nor model; they remain valid.

Add a reducer with source and race semantics:

```text
requested route                         display fallback only
thread start/resume response or settings notification
                                      provider-reported baseline
assistant/response model               per-response observation
model reroute                           authoritative over an in-flight baseline lookup
```

Every asynchronous baseline lookup captures the current observation revision.
Ignore its result when a reroute or later provider observation has advanced the
same turn/agent. Apply stale-generation, turn-ownership, and agent-ownership
checks before every update. Timestamp order alone is insufficient.

### B2. Capture root effective models

Codex:

- retain the provider-reported model returned by `thread/start`;
- retain the provider-reported model returned by `thread/resume`, including a
  resume completed during prewarm before the send path takes its loaded-thread
  fast path;
- handle root `thread/settings/updated`;
- handle root `model/rerouted`; and
- emit a provider-neutral, turn-scoped root model observation.

Claude:

- record the provider-reported model from the first root assistant frame;
- retain the terminal usage/model observation; and
- update effective attribution when the existing refusal fallback reroutes.

Direct OpenAI:

- capture `response.model`.

Do not derive root model identity from the latest generic activity record.
Ordinary tool/state records are currently stamped with the requested route and
could otherwise downgrade a newly observed effective model. A child record must
also never determine the root model. Store pure model observations as durable
metadata without manufacturing a lifecycle state.

The selected-turn root projection resolves provider access and model
independently, using only explicit root observations for that turn.

Tests:

- requested and returned models differ;
- resume returns a model before any activity event;
- prewarm retains the resume model through the loaded-thread fast path;
- a later reroute wins;
- a delayed baseline response arriving after a reroute is ignored;
- later requested-route activity cannot downgrade the reported model;
- child and unknown-thread observations cannot update root;
- an idle settings event cannot rewrite a previous completed turn;
- Claude fallback is reflected without changing the picker;
- direct OpenAI records `response.model`;
- missing `response.model` retains a visibly requested root fallback; and
- historical turns retain their provider/model through model changes and
  relaunch.

### B3. Close the Codex child-model gap

Start with a bounded protocol spike against the pinned 0.144.6 App Server:

1. Spawn a real child.
2. Discover its thread from `thread/started.thread.parentThreadId` when
   present, or from the first authoritative
   `subAgentActivity.agentThreadId` when the optional parent link/event is
   absent.
3. Issue one deduplicated
   `thread/resume { threadId, excludeTurns: true }`.
4. Verify that the response exposes the provider-reported thread model.
5. Verify that resuming an already-active child is non-mutating, cheap, and
   does not alter event delivery or ownership.

If safe, make this a nonblocking child metadata lookup and emit the existing
`workflow_update.model` field. Buffer the observation when it arrives before
child ownership, as current settings/reroute events already do.

Do not call the current `beginCodexThreadResume` unchanged. Its warm-state fast
path returns only a Boolean and discards response metadata. Refactor the
warm-state cache to retain thread response metadata, or add a separate
single-flight metadata lookup with bounded timeout and no retry storm.

If active-child resume is not safe, the durable solution is an upstream App
Server field on `Thread`, `thread/read`, or the initial child lifecycle. Do not
parse provider rollout JSONL in production.

Pin these protocol fields in the schema verifier:

- `ThreadResumeResponse.model`;
- `ThreadResumeParams.excludeTurns`;
- `ThreadStartedNotification.thread.id` and optional `parentThreadId`;
- `ThreadSettingsUpdatedNotification.threadId` and
  `threadSettings.model`; and
- `ModelReroutedNotification.threadId`, `turnId`, `fromModel`, and `toModel`.

Tests:

- no initial settings event, but metadata lookup returns a model;
- missing/duplicate `thread/started` falls back to `subAgentActivity`;
- exactly one lookup per child;
- lookup never blocks the parent turn;
- an early observation survives ownership registration;
- reroute supersedes initial identity;
- delayed lookup after reroute cannot overwrite it;
- nested children remain independently attributed;
- lookup timeout, provider restart, terminal-before-response, and background
  conversation switching are harmless;
- failures do not create retry storms;
- aliases and terminal updates retain the model; and
- failure renders `Model not reported`, not the parent model.

### B4. Correct activity attribution, badges, and search

Today delegated activity records can inherit the root turn's selected model.
Change attribution so:

- root lifecycle records may carry requested routing metadata, but root model
  display comes from the turn-scoped reducer;
- child records initially carry provider access only;
- a provider-reported child model is applied only to that child's lane;
- historical unknown child models remain unknown.

Populate/persist child `providerAccess` from the owning provider route.
Presentation badge examples:

```text
Root · Claude · claude-sonnet-…
Explore · Claude · claude-sonnet-…
Codex · gpt-5.6-sol
Codex · Model not reported
```

When role/type equals the provider display name, render it once. Extend child
and workflow card search to include provider, role/type, and model display text.
The root card remains structural and is not filtered out by child search.

Acceptance:

- Every card resolves provider/role separately from model and avoids duplicate
  badges.
- Claude + role + model, Codex + model, provider-known/model-unknown, and
  legacy-attribution layouts are covered.
- Effective model survives relaunch and updates on reroute.
- A child never displays a model based only on its parent.
- Missing provider data is visible rather than silently omitted.

## Workstream C: root-agent card

### C1. Add a selected-turn root snapshot

In `AgentStepInsight.swift`, add `AgentRootActivitySnapshot` with:

- selected turn ID;
- provider access;
- turn-scoped requested/provider-reported model attribution;
- root lifecycle phase;
- root start and root-terminal timestamps;
- current-step snapshot;
- root-only token breakdown;
- root-only observed tool count;
- root-only tool composition;
- stall state;
- active state; and
- elapsed root duration.

Add:

```swift
AgentConversationActivityIndex.rootSnapshot(isRootWorking:now:)
```

Derive it from the exact same `AgentConversationActivityIndex` instance and
revision used by the conversation summary—never the panel's full-ledger
`activityIndex`. Use the selected-turn records already filtered inside that
index, then use
`turnIndex.cardSnapshot(agentID: .root)`. Cache the selected root states during
index construction so one-second ticks do not rescan the full ledger.

Root lifecycle rules:

- `isActive` reflects root work only, not a child that remains active;
- duration ends at the root terminal record, not the selected turn's final
  child record;
- a turn containing only child or maintenance records does not create a root
  card;
- idle/resume compaction cannot reactivate or extend a terminal root; and
- `compacting` on the root card means provider compaction inside an active root
  turn, not post-turn maintenance.

Correctness tests:

- child records are excluded;
- prior turns are excluded;
- maintenance-only records do not synthesize a root;
- root delegation remains root tool activity;
- active-turn/latest-turn selection matches the conversation summary;
- root duration freezes while a child continues; and
- late buffered progress cannot reopen a terminal root.

### C2. Audit root tool coverage

Codex already emits root activity for command execution, file changes, MCP
calls, web search, and dynamic Mechanician tools. Audit native collaboration,
image view, sleep/wait, and image-generation items.

For each supported item:

- map it to a stable activity-only tool name and target;
- deduplicate start/completion by provider item ID;
- represent agent spawning as `Delegating`;
- avoid adding transcript tool cards merely to improve Activity metrics; and
- keep the user-facing metric named “observed tools.”

Contract tests must prove that parentless tool/usage events go to root and
child-owned events never leak into root totals.

C1 and the first card version can proceed using the currently observed tool
set and the honest “observed tools” label. C2 runs in parallel, but complete
coverage for every supported native Codex item—especially exactly-once
`Delegating` activity—is a release gate for claiming the audit complete.

### C3. Add the root card presentation

Add a pure `appKitRootAgentCardPresentation(...)` beside the existing
child/workflow presentation functions.

Content:

- badges: `Root`, provider, effective/reported model;
- state: working, waiting, compacting, completed, failed, or stopped;
- current-work band using existing step text;
- root processed tokens;
- root observed tool count;
- root-only tool composition;
- root start time; and
- root elapsed duration.

Do not fabricate a prompt, result summary, or error from transcript entries
that cannot be safely joined to the selected turn.

The root card has no detail pane in this slice. Mark it as a non-actionable
accessibility group and omit the disclosure chevron. If root-filtered Activity
navigation is added later, it can become actionable then.

If the root is active, its Stop control invokes a new owner-routed root
interrupt, not child `stopTask` and not the broader
`stopConversationWork()` operation. It cancels the root turn or its queued
pre-send prompt while leaving independently running children alone when the
provider permits. A duplicate window forwards the request to the owning bridge.
Hide it once the root terminalizes, even when children are still running.

The root card uses the shared road-sign Stop artwork from Workstream D.

### C4. Add a structural root row

Rename `AppKitRootAgentSummaryView` to
`AppKitConversationSummaryView`; it is a conversation rollup, not a root card.

Extend `AppKitAgentsListItem` with `.root` and place it:

1. below the pinned conversation summary;
2. before delegated-agent groups; and
3. outside Active / Needs attention / Completed child counts.

Behavior:

- show it whenever the selected active/latest turn has root activity;
- keep it visible while filtering child agents;
- pass explicit root presence into `AppKitAgentsListSnapshot.make` and retain
  `previousRootPresence`;
- preserve the true empty state before any root turn exists;
- derive table emptiness from structural/root presence, not delegated count;
- when only root exists, omit delegated-agent search controls;
- rebuild the table graph once when root presence changes;
- refresh the existing row and invalidate height only when needed for token,
  tool, state, and elapsed-time updates;
- never rebuild the table graph or activity index on one-second ticks;
- add a `.root` cell content case with `pressHandler = nil`, no row selection,
  accessibility role `.group`, and no disclosure chevron;
- do not call the root `A0` or shift child ordinals.

Accessibility must distinguish “This conversation” from “Root agent.”
Child search may match provider/role/model; the structural root row remains
visible and is not itself filtered.

Tests:

- root row precedes child groups;
- child group counts do not include root;
- root-only state renders with and without children;
- requested and provider-reported model badges are honest;
- Stop uses the owner-routed root interrupt only;
- duplicate-window Stop reaches the owner;
- root Stop does not call the delegate-wide stop path;
- root-only content suppresses the delegated empty state and search controls;
- the row has no false disclosure action;
- ticks and ordinary metric updates do not rebuild the table/index;
- narrow, compact, and full layouts do not overlap; and
- root state and metrics survive relaunch.

## Workstream D: matching Stop road sign

The desired artwork already exists as `ComposerRoadSign(kind: .stop)`. The
native AppKit cards need a reusable `NSImage` bridge.

### D1. Promote a shared cached renderer

In `ComposerSigns.swift`, add a main-actor renderer:

```swift
ComposerRoadSignImage.image(kind:size:) -> NSImage
```

Requirements:

- make `ComposerRoadSignKind` `Hashable` and import AppKit for the bridge;
- render the exact flat, static form
  `ComposerRoadSign(kind:size:highlighted:false,raised:false)`;
- render at 2× backing resolution;
- set the intended logical image size;
- set `isTemplate = false` so AppKit does not recolor the artwork;
- cache immutable images by road-sign kind and logical size;
- accept only finite positive sizes and keep the cache bounded to the small
  fixed sizes used by the app;
- return a programmatically drawn octagonal Stop fallback if SwiftUI
  `ImageRenderer` unexpectedly fails on a supported runtime—never silently
  return an invisible image or fall back to `stop.fill`; and
- make the existing delivery menu use the same renderer.

Hover highlighting remains owned by the native button in this slice; the
cached artwork itself is unhighlighted.

### D2. Replace only interactive Stop controls

Replace `stop.fill` in:

- the native agent card in `AppKitAgentsPanel.swift`;
- the native agent detail header in `AppKitAgentsPanel.swift`; and
- the inline transcript workflow card in `WorkflowViews.swift`.

The new root card must use this shared artwork from its first implementation.

Use a 16–18 point sign inside the existing 22×22 card button and 23×23 detail
button. Set `imageScaling = .scaleProportionallyDown` and
`imagePosition = .imageOnly`. Remove the red `contentTintColor`, but preserve
the current action routing, keyboard behavior, and hit target.

Configure the tooltip and accessibility label every time a recycled detail
view changes content:

```text
subagent                Stop this agent
workflow/workflow agent Stop this workflow
root                    Stop root agent
```

This also fixes the existing workflow-to-subagent reuse bug, where an old label
can survive on the recycled detail button.

The inline SwiftUI workflow action becomes an explicit
`HStack { ComposerRoadSign(...); Text("Stop") }`. Hide the decorative sign from
accessibility and keep the text as the accessible name.

Do not replace terminal-status `stop.circle.fill` glyphs. Those describe state;
the octagonal road sign is specifically the interactive Stop action.

Automated tests:

- shared renderer returns a non-template, nonempty image at the requested
  logical size and exercises its fallback seam;
- repeated requests use the cached image;
- agent card and detail Stop controls retain their accessibility text and
  dispatch the same target ID;
- recycled workflow → subagent detail resets tooltip and accessibility label;
- root card uses the shared image and its action reaches root interruption;
- inline workflow Stop retains its action;
- a hosted mouse/accessibility activation test proves Stop does not also
  activate the table row or expand the inline workflow header; and
- compact/nested layout render tests do not overlap.

If the current inline header gesture cannot support a real propagation test,
extract the Stop control or restructure the header so expansion and Stop have
independent event surfaces. A direct closure call or `performClick()` alone is
not proof that the containing row gesture did not fire.

Run focused coverage in the renderer/delivery-menu tests,
`AppKitAgentsPanelTests`, the Stop-button interaction tests, and the existing
agent-card layout/trace-render harness.

Manual visual checklist:

- flat octagon matches the composer in light and dark appearances;
- native hover/pressed/focus states remain readable;
- compact and nested cards remain aligned; and
- VoiceOver announces the correct action once.

Land D1 (renderer and delivery menu) separately from D2 (panel/inline
consumers). D2 and the root-card table work both edit
`AppKitAgentsPanel.swift`; assign that file to one slice at a time or integrate
the root control in the same branch to avoid conflicts.

## Workstream E: MCP tool-discovery contract and lookup latency

This is a high-priority correctness and initial-response-performance bug. A
reported VICE lookup showed that the generated instructions described the
server as deferred and directed the agent to a nonexistent `ToolSearch` skill,
even though `mcp__VICE__*` tools were already directly callable. The resulting
detour spawned a broad-tools subagent and produced incorrect user-facing claims
that VICE was inaccessible.

### E1. Make the runtime tool inventory authoritative

Audit the instruction builder against the exact tool inventory delivered to
the main agent for each provider/surface. At prompt construction time:

- if an MCP tool is present in the main agent's callable tool inventory,
  describe it as directly callable and do not mention discovery;
- if a tool is genuinely deferred, name only the discovery primitive that is
  actually exposed in that same runtime;
- never describe `ToolSearch` as a skill;
- omit all deferred/discovery language when no working discovery primitive is
  present; and
- reduce the MCP readiness preamble to the authenticated/needs-auth status and
  the minimum accurate invocation guidance.

The tool inventory—not prose configuration—is ground truth. Add a startup
contract assertion or generated-instruction test that fails when instructions
reference a tool/skill name absent from the exposed inventory.

### E2. Prefer direct calls for single-fact lookups

Add provider-neutral guidance and regression coverage:

- a one-person VICE lookup directly calls `mcp__VICE__vice_get_user`;
- one-step directory/search lookups do not spawn a subagent;
- before claiming that an integration is unavailable, attempt the available
  direct tool or report the concrete authentication/error result;
- subagents remain appropriate for genuine independent fan-out, not as a
  substitute for one already-exposed tool; and
- an unavailable deferred server produces one clear, truthful error rather
  than a speculative harness limitation.

Capture time-to-first-tool-call and number of delegated agents in the
performance fixture so this regression cannot return unnoticed.

### E3. Prevent giant-page retrieval for narrow questions

For Confluence-like connectors, prefer search-result excerpts or section-scoped
fetches before retrieving a full page. Where the connector supports neither,
add a response-size guard that:

- exposes byte/character estimates before injecting a large result;
- asks the agent to narrow the query or use an excerpt when available;
- keeps a deliberate full-page escape hatch for tasks that truly need it; and
- records only sizes and operation names in diagnostics, never page content.

Add a fixture where extracting one attendee line succeeds from a search
excerpt without injecting a roughly 15 KB agenda.

### E4. Audit instruction/tool parity

Search every generated provider preamble and skill/capability instruction for
named primitives. For each reference, prove one of:

1. the primitive is directly callable by the main agent;
2. a working discovery mechanism can expose it; or
3. the instruction is conditional and omitted when unavailable.

Release acceptance:

- the VICE reproduction completes with one direct main-agent tool call;
- no `Unknown skill: ToolSearch` path remains;
- the agent does not falsely report an exposed MCP server as inaccessible;
- no subagent is created for the single lookup;
- narrow Confluence lookups avoid full-page payloads when excerpts suffice;
- generated-instruction/tool-inventory parity tests run in CI; and
- the change is verified on every provider surface that supplies MCP tools,
  not only the originally reported harness.

## Workstream F: actionable Claude connection recovery

This is a high-priority account-recovery UX bug. The captured failure card says
that Claude credentials could not be verified, reports
`status_unavailable`, and offers only Anthropic status, error help, and Retry.
There is no action that lets the user reconnect Claude from the failure itself.

### F1. Separate “reconnect offered” from “reconnect required”

The current recovery policy treats a reconnect action as equivalent to a
definitive authentication failure. That is too narrow for non-definitive
credential-probe and provider-connection failures.

Add a separate recovery decision:

```text
reconnectRequired   definitive authentication failure; account is unusable
reconnectOffered    reconnect is a useful explicit recovery action
```

For Claude subscription failures such as `credential_unknown`,
`credential_network`, and the captured `status_unavailable` probe result:

- keep verification deferred when the failure is non-definitive;
- do not sign the account out or mark it disconnected;
- retain Retry when retrying the request is safe;
- also offer **Reconnect**; and
- make that action force a fresh Claude connection flow even when the account
  store still considers the existing account connected.

A definitive authentication rejection continues to require reconnection and
must not be weakened into an optional retry-only state.

### F2. Render the action on every relevant failure surface

Use the same structured provider-recovery action for:

- foreground transcript failure cards;
- background-agent failures;
- restored/persisted failure cards; and
- compact and expanded presentations.

Do not infer the button from error-message text in the view. Normalize the
provider failure once, carry a provider/account-specific recovery action, and
let the existing action renderer present it. The button must remain visible in
large text, have an unambiguous accessibility label, and invoke the forced
Claude reconnect path rather than a no-op “already connected” check.

### F3. Add the captured regression and recovery tests

Create a fixture matching the screenshot:

```text
provider: Claude subscription
providerType: credential_unknown
code: status_unavailable
message: Claude credentials could not be verified before the request started.
```

Assert that:

- the card renders both Retry and **Reconnect**;
- the failure does not call the definitive-account-disconnect path;
- selecting Reconnect invokes a fresh Claude sign-in;
- a definitive 401/authentication rejection still requires reconnect and does
  not incorrectly offer Retry;
- credential-network failures receive the same useful recovery action;
- foreground, background, and restored failures preserve the action; and
- tolerant decoding keeps legacy failure records valid.

Release acceptance:

- every Claude authentication, credential-verification, or connection failure
  provides either a working reconnect action or a documented reason that
  reconnect cannot help;
- the exact `credential_unknown` / `status_unavailable` reproduction visibly
  includes **Reconnect**;
- clicking it starts a fresh Claude connection flow; and
- non-definitive probe failures do not silently sign out a valid account.

## Primary file map

| Area | Primary implementation files | Primary tests |
| --- | --- | --- |
| Context-maintenance policy/adapters | `agentd/src/agentd.mjs`, new `agentd/src/context-maintenance-policy.mjs`, `agentd/src/codex-workflows.mjs`, new `agentd/src/codex-context-maintenance.mjs`, `agentd/src/claude-context-guard.mjs`, `agentd/src/claude-turn-options.mjs` | shared policy tests, fake App Server lifecycle tests, `claude-context-guard.test.mjs`, `claude-context-recovery.test.mjs`, `claude-turn-options.test.mjs` |
| Context persistence/coordinator/swimlanes | `app/Sources/Mechanician/AgentBridge.swift`, `ConversationStore.swift`, `AgentActivityTimeline.swift`, `AppKitAgentsPanel.swift`, `LayerBackedActivityViews.swift` | conversation persistence, provider contract, legacy-sidecar, lifecycle diagnostics, `AgentActivityCompactionSpanTests.swift`, `AgentTraceRenderTests.swift`, `AppKitAgentsPanelTests.swift` |
| Model attribution | `agentd/src/agentd.mjs`, `codex-workflows.mjs`, `claude-message-events.mjs`, `app/Sources/Mechanician/WorkflowStore.swift`, `AgentActivityTimeline.swift` | schema verification, Codex/Claude integration, `WorkflowStoreTests.swift`, activity ledger tests |
| Root projection/card | `app/Sources/Mechanician/AgentStepInsight.swift`, `AppKitAgentsPanel.swift`, `AgentBridge.swift` | `AgentActivityLedgerIndexTests.swift`, `AppKitAgentsPanelTests.swift`, `ProviderContractTests.swift`, `AgentTraceRenderTests.swift` |
| Stop artwork | `app/Sources/Mechanician/ComposerSigns.swift`, `ComposerDeliveryMenu.swift`, `AppKitAgentsPanel.swift`, `WorkflowViews.swift` | renderer/menu, Stop interaction, AppKit panel, layout/trace-render tests |
| MCP instruction/tool parity | prompt/instruction builders, main-agent tool inventory assembly, connector result adapters | generated-instruction parity, direct VICE lookup, no-subagent routing, excerpt/size-guard fixtures |
| Claude connection recovery | `agentd/src/provider-preflight.mjs`, `app/Sources/Mechanician/ProviderFailure.swift`, `ContentView.swift`, `AgentBridge.swift` | preflight normalization, recovery-policy, failure-card action, reconnect-routing, persistence tests |

## Delivery sequence

### Morning start: first 90 minutes

1. Preserve the current dirty worktree and isolate focused implementation slices on `main` without
   rewriting unrelated changes.
2. Turn the captured 220,607 / 258,400 case into a named policy fixture.
3. Pin the exact 0.144.6 `thread/compact/start` lifecycle schema.
4. Pin Claude's effective-usage, native-threshold, compaction-lifecycle, and safe-rollover
   contracts with fake SDK fixtures.
5. Add the pure maintenance policy with the 82% idle and 88% projected tests for both adapters.
6. Run the live, non-mutating Codex child-model metadata spike.
7. Record baseline high-context TTFT, cached-input diagnostics, and retained-decision quality for
   Claude and Codex before behavior changes.

At the 90-minute checkpoint, the team should know whether child
`thread/resume(excludeTurns: true)` is safe, have both maintenance capability contracts pinned, and
have the shared policy locked by tests.

### Dependency-ordered slices

| Slice | Scope | Depends on | Gate |
| --- | --- | --- | --- |
| 1 | Telemetry, Codex/Claude contract pins, pure maintenance policy | none | privacy, capability, and policy tests |
| 2 | Codex explicit adapter plus Claude native/rollover/replay adapter | 1 | both exact lifecycle/race matrices |
| 3 | Swift coordinator, persistence, Activity lines, and all maintenance swimlane modes | 2 | cross-window, relaunch, rendering, and accessibility tests |
| 4 | Enable provider-appropriate proactive maintenance behind a default-off preference | 3 | per-provider latency, cache, failure, and quality benchmark |
| 5 | Turn/agent-scoped provider/model schema + root capture | none | reducer, persistence, provider contract tests |
| 6 | Codex child-model lookup or upstream fallback | protocol spike | child model integration tests |
| 7 | Root selected-turn snapshot + pure presentation | B1 schema portion of 5 | ledger isolation/presentation tests |
| 8 | Root native-tool coverage audit | none | provider exactly-once contract tests |
| 9 | D1 shared Stop renderer + delivery menu | none | renderer/cache tests |
| 10 | Root structural row + D2 Stop consumers | 7 and 9 | AppKit/action/layout/accessibility tests |
| 11 | Prefix stability/lazy schemas and cold-resume option | 4 | cache-ratio benchmark |
| 12 | Actionable Claude reconnect recovery | none | exact `status_unavailable` failure-card and forced-reconnect tests |

Slices 1–4 are the P0 latency path. Slices 5, 8, 9, and 12 can begin in
parallel.
Root metric/index work needs only B1's turn-scoped attribution schema; it does
not wait for the Codex child-model lookup. Root card presentation waits for the
turn-scoped root reducer, not for all child model coverage. Serialize slice 10's
edits to `AppKitAgentsPanel.swift` with any overlapping work already in the
dirty tree.

Root-card implementation/test order:

1. selected-turn/root-index unit tests;
2. pure root presentation tests;
3. structural placement, root-only empty-state, and filtering tests;
4. cell ticking, root Stop routing, and accessibility tests;
5. provider tool/model contract tests;
6. persistence and duplicate-window tests; and
7. render/layout plus no-rebuild performance tests.

## Test and benchmark matrix

### Automated

Run:

- agentd unit and integration tests;
- shared policy and provider-capability tests;
- pinned Codex schema verification;
- fake App Server compaction lifecycle and fault injection;
- fake Claude SDK context-usage, launch-policy/read-back, native-compaction, bounded-rollover, and
  bounded-history-replay lifecycle tests;
- Swift persistence/legacy-sidecar tests;
- Activity ledger, compaction-span, rollover-marker, and selected-turn index tests;
- provider contract tests;
- Agents panel presentation/layout tests; and
- trace-render overlap tests.

Required scenarios:

- fresh session on each provider;
- small resumed session on each provider;
- 85% warm resumed session;
- 85% cold resumed session with zero cached input;
- prompt just below and just above projected threshold;
- tool-heavy turn that grows context rapidly;
- one Mechanician-controlled attachment/MCP result that exceeds the single-input reserve;
- one provider-owned built-in result that cannot be intercepted, followed by authoritative
  post-result usage and maintenance before the next send;
- active child and completed root;
- approval and user-input wait;
- two windows on one conversation;
- model/session/process-generation switch;
- prompt collision with scheduled and active maintenance;
- Stop during pre-send maintenance;
- dropped, duplicate, reordered, and early provider notifications;
- provider restart during maintenance;
- native compaction with unknown pre/post token counts;
- Claude's launch percentage rounded down correctly, included in warm identity, then verified
  against the effective token threshold;
- Claude's effective native threshold later than 88%, plus disabled, ignored, timed-out, and
  route-inapplicable launch policy;
- Claude projected usage crossing 88% only because of completion/policy-only reserve while
  `nativeTriggerInput` remains below the read-back threshold, forcing rollover before enqueue;
- idle preparation deduped by sample, effective threshold, and provider generation, with no
  rollover while idle;
- successful Codex compaction whose post-usage plus unchanged prompt still fails the final gate;
- bounded rollover with omitted and shortened history but no `compact_boundary`;
- bounded history replay with no source provider session, no fabricated retirement claim, and a
  distinct non-compaction marker;
- rollover source/destination session identity and allowlisted reason surviving stale-session
  filtering;
- operation-ID and legacy same-turn history-reduction projection deduplication;
- no automatic replay after model, tool/task/hook, guidance, interruption, or unknown
  side-effect-capable events;
- one failed-inline Claude compact that enqueues twice but performs side-effecting work only in the
  fresh stream;
- a controlled old-constraint/decision quality fixture scored separately for provider-native
  compaction and bounded context reduction;
- root/child model reroutes; and
- relaunch after completed and failed native compaction, rollover, and bounded history replay.

### Live measurement in the running app

Use disposable Claude and Codex conversations plus a real high-context resumed conversation on
each provider route included in the rollout.

For each run, capture:

- context/window ratio before send;
- context age;
- cached input tokens;
- prewarm duration;
- maintenance decision, selected operation, and duration;
- provider request acknowledgement (`turn/start` for Codex and the corresponding Claude stream
  handoff);
- time to first reasoning;
- time to first text; and
- context size after maintenance, with rollover omission/shortening counts when applicable.

Run the applicable cases on both providers:

1. warm follow-up below threshold;
2. warm high-context idle maintenance;
3. immediate follow-up that cancels the idle debounce;
4. prompt that joins active maintenance;
5. app relaunch into a high-context cold session;
6. tool-heavy turn;
7. subagent turn;
8. model switch;
9. provider restart; and
10. manual Stop while the prompt waits.

Additionally force the Claude later-threshold/native-failure path through one safe bounded rollover
and the Codex explicit-compaction failure path through prompt retention. Confirm the former creates
a rollover marker, not a compaction boundary. Also force bounded history replay with no prior
provider session and confirm its marker does not claim retirement. Confirm Codex sends at most one
`turn/start`, while a Claude safe replay may enqueue twice only when the old stream proves zero
side-effecting work.

## Rollout and safeguards

Ship proactive context maintenance behind a runtime feature flag with:

- a master kill switch plus independent provider/operation kill switches;
- centrally versioned defaults and explicit provider/model threshold overrides;
- capability observations for every provider route;
- per-trigger counters;
- native-compaction, rollover, failure, and retry counters;
- zero-cache/high-input alerting; and
- redacted diagnostics export.

Roll out the Claude and Codex adapters independently; success on one is not evidence that the other
provider's control surface is safe. For each adapter:

1. tests only;
2. internal opt-in;
3. internal default-on;
4. limited release cohort;
5. default-on after latency and failure gates pass.

Do not retry failed maintenance repeatedly against the same sample. A new
context sample, explicit user action, or provider restart may permit one new
attempt.

## Release acceptance criteria

### Performance

- A high-context conversation receives provider-appropriate preparation or native compaction during
  idle/resume whenever possible, before the user sends.
- When pre-send maintenance is unavoidable, an Activity line appears within
  250 ms; there is no unexplained minute-long blank state.
- The captured 220,607 / 258,400 regression compacts before `turn/start`.
- On Claude, `shouldCompact=true` cannot proceed merely because the reported native threshold is
  later. The launch-time threshold is verified before enqueue, and the actual provider-trigger
  input—not the completion reserve—must reach it. Native compaction then runs inline before
  side-effecting model work, or one safe bounded rollover happens before enqueue.
- Codex sends zero or one `turn/start`. Claude performs at most one side-effecting provider/model
  execution; its sole allowed second transport enqueue follows proof that the old stream performed
  no model/tool/task/hook/guidance work.
- A bounded rollover, or a history replay that reduces history, emits a durable non-compaction
  Activity entry, a distinct Trace event/root-lane presentation, and a distinct Usage
  context-pressure marker, including after switching conversations or relaunching.
- Rollover/replay omitted and shortened counts and accessibility text are accurate; retirement copy
  appears only when a source session existed, and neither operation increments the compaction
  count.
- Fresh and small resumed conversations do not run unnecessary maintenance.
- A high-context, post-maintenance conversation begins reasoning within 10 seconds in at least four of
  five runs per provider, barring a separately identified provider outage.
- Cache impact and retained-decision quality are reported separately for native compaction and
  bounded context reduction before either adapter becomes default-on.
- Native compaction must meet a pre-registered non-inferiority band against that provider's normal
  continuation policy; bounded rollover/replay remains a disclosed recovery path and is never
  promoted to ordinary maintenance merely because it is faster.
- Median fresh-thread TTFT does not regress by more than 10%.
- No quiet provider operation is killed solely for taking time.

### Model identity

- Provider, agent role/type, and model are independently resolved and
  deduplicated on every card.
- Root effective identity is turn-scoped, comes from provider
  start/resume/response events, and updates on reroute.
- A delayed baseline lookup cannot overwrite a reroute.
- Codex child identity is obtained safely or shown as not reported.
- Child cards never inherit an unconfirmed parent model.
- Requested values are visibly labeled as requested.
- Historical attribution survives model switches and relaunch.

### Root card

- The conversation summary remains aggregate-wide.
- The root card contains only the selected root turn's state, tokens, tools, and
  duration.
- Child and prior-turn metrics never leak into it.
- Root duration stops at root terminalization.
- Maintenance-only activity never creates or reactivates a root card.
- Root tool coverage is deterministic and labeled “observed tools.”
- Root Stop reaches the owning root interruption path without invoking
  delegate-wide Stop.

### Stop icon

- Every interactive agent Stop action uses the composer road-sign artwork.
- No control is recolored into a red square.
- Existing action routing and hit targets remain unchanged.
- Recycled detail tooltips/accessibility labels always match the current
  subagent, workflow, or root action.

## Out of scope for the first implementation

- Replacing provider-native compaction with a Mechanician-authored summary.
- Parsing Codex rollout files to discover model identity.
- Sending synthetic warm-up turns.
- Rebuilding the Agents panel architecture.
- Counting unobserved provider-internal tools as if they were authoritative.
- Changing terminal state icons that happen to use a stop symbol.
- Making the root card a fabricated transcript/detail view.
