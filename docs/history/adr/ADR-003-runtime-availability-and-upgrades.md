# ADR-003: Runtime availability, admission, and compatible upgrades

> **Superseded. Archived history. Do not implement anything in this file.**
>
> This ADR governs the Runtime Service in [ADR-001](ADR-001-runtime-service.md), which was built,
> shipped, and reverted on 2026-07-20. Every mechanism it decides (XPC connectivity as a separate
> authority, service-fenced helper upgrades, a durable outbox that survives transport loss) exists
> only because the app and its runtime had been split into separate processes. They were not split
> back apart afterwards, so none of this machinery is in the repository.
>
> What replaced it: `agentd` is a child process the app spawns and owns. Each workspace window runs
> its own `agentd` per provider lane (`AgentBridge.bridgeID` exists because of that), and closing a
> window kills its `agentd`. App and daemon therefore always ship together at the same version,
> so there is no negotiation and no upgrade handshake to get wrong. The trade is that window
> lifetime still bounds turn lifetime, which is the problem this ADR was trying to remove. See
> [docs/architecture/AGENTD-PROTOCOL.md](../../architecture/AGENTD-PROTOCOL.md).
>
> One idea in here did survive the revert, and it is the most useful thing in this file: do not
> collapse independent facts into one readiness bit. "Connected", "authenticated", "has a model
> catalog", and "can accept this command" are four separate questions, and answering them with one
> boolean is what makes a reconnect look like a logout. [The history index](../README.md) states
> that rule in general form.

- Original status: accepted
- Date: 2026-07-19

## Context

The app formerly projected one `isReady` bit across four independent facts: XPC connectivity,
provider authentication, model discovery, and whether a user command could be durably accepted.
That coupling made a transient reconnect disable Enter and erase the usable model presentation even
though the app owned a durable outbox and a previously authenticated provider snapshot.

The compatible-upgrade path also inferred a new helper behavior from version ordering. A new app
immediately fenced an older, wire-compatible helper before asking it for provider snapshots. Helpers
released before durable drain support could not satisfy that assumption, leaving both providers
permanently unavailable.

## Decision

Mechanician treats transport, provider state, catalog state, command admission, and upgrade state as
separate authorities.

1. `live transport` answers whether ephemeral control can be sent now.
2. `durable admission` answers whether a user turn can be committed atomically to the app outbox.
   Once a compatible presentation session has established and projection storage is healthy,
   transient transport loss does not revoke durable admission.
3. `provider snapshot` is authoritative for authentication and account mode. Reconnect marks live
   controls unavailable but does not fabricate a logout.
4. `model catalog` is cached only for an exact provider account instance. Reconnect may present that
   stable catalog; logout, account replacement, or credential rotation cannot inherit it.
5. `compatible upgrade` is an explicit state machine. An older helper that omits the negotiated
   durable-drain capability remains live through bootstrap and handoff. A capable helper is fenced
   only after it acknowledges `upgradePending`; a legacy helper is fenced only at
   `readyForReplacement`.
6. Every attached provider lane must deliver a fresh ready snapshot before the app asks an older
   helper to drain. Catalog requests queued by that snapshot are admitted before the drain request.
7. Durable commands accepted while disconnected or fenced retain their stable command and route
   identity and replay after the next compatible session. Ephemeral commands fail closed.

The UI derives submission, live controls, provider authentication, and picker presentation from
those distinct states. It does not reconstruct any of them from a single connectivity flag.

## Release invariants

- Generated protocol sources and compatibility tests must cover an N-1 helper that omits every new
  optional capability.
- Builds and releases share one atomic artifact lock. A release aborts if source HEAD or the working
  tree changes while the candidate is assembled.
- Tests never append to the production transport diagnostic timeline.
- Publication requires the exact signed candidate to be installed with its exact helper active.
- After the latest exact-build presentation session, the installed app must record privacy-safe
  evidence that Claude subscription and Codex subscription each produced an authenticated provider
  snapshot, a non-empty model catalog, and a completed real conversation turn.

## Consequences

Provider reconnection can temporarily disable live-only actions without blocking new durable user
turns. A queued turn may not start immediately, but it is not lost and the UI must present it as
queued. Cached model rows remain stable across transport loss but never cross account identity.

Adding an upgrade optimization now requires an explicit negotiated capability and a legacy path.
Source tests are necessary but insufficient to publish; real subscription acceptance is a release
transaction input.
