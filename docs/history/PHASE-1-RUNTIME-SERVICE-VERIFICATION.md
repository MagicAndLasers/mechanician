# Phase 1 Runtime Service verification

> **Superseded. Archived history. Nothing here is pending, and nothing here should be built.**
>
> This is the acceptance checklist for the Runtime Service, which was built, shipped, and reverted
> on 2026-07-20. The `MechanicianRuntimeService` LaunchAgent, the authority epoch, and the
> provider-generation fencing it verifies were all removed with the service.
>
> What replaced it: the app spawns `agentd` directly and owns it, so there is no per-user service
> to admit, fence, or upgrade. See
> [docs/architecture/AGENTD-PROTOCOL.md](../architecture/AGENTD-PROTOCOL.md) for the shipped
> boundary and [the history index](README.md) for why the service was abandoned.
>
> Read this file only as a record of what the design was expected to guarantee. Some of those
> guarantees were later met by different mechanisms (a single-writer lease on the library database,
> quarantine of undecodable records) and those are described in
> [docs/architecture/STORAGE-AND-PERSISTENCE.md](../architecture/STORAGE-AND-PERSISTENCE.md).

Original status: source verification complete; assembled-bundle and signed installed-build
acceptance pending.

This record defines what must be true before the first Runtime Service build is
published. It separates properties proved by deterministic source tests from
properties that can only be proved by installing two consecutively signed and
notarized application builds.

## Scope

Phase 1 moves provider and ambient runtime ownership out of application windows
and into one per-user, signed `MechanicianRuntimeService`. It introduces the
versioned protocol and the minimum durable control ledger required to make that
boundary honest. It does not claim to complete the normalized product-state
ledger, snapshot/compaction system, repository leases, or execution isolation
described by later programs in the architecture plan.

The Anthropic subscription authentication path and product policy are unchanged.
The service supervises the same bundled SDK/CLI integration; subscription
credentials do not enter the Runtime Service protocol.

## Required guarantees

### Authority and lifecycle

- Production uses one `SMAppService` LaunchAgent and never silently falls back
  to a window-owned provider.
- The service holds the per-user authority lock and a monotonic SQLite authority
  epoch before starting any provider process.
- Multiple windows negotiate with the same service and provider generations.
- Closing every window does not cancel accepted turns, workflows, terminals, or
  enabled ambient scheduling.
- Service restart fences dead provider generations and exposes ambiguous work as
  a recoverable orphan instead of redispatching it blindly.
- Provider failure or generation replacement atomically fences the lost
  generation, emits typed provider state plus ordinary recovery facts for each
  newly orphaned activity, resolves in-flight cancellation records, and revokes
  generation-bound capability leases. A replayed event from the retired
  generation may advance its durable cursor but cannot mutate replacement UI.
- A compatible update quiesces ambient claims, drains active work and durable
  outboxes, checkpoints, receives an app acknowledgement, and only then exits.

### Protocol and transport

- One checked-in Protocol Buffers schema generates Swift and Node sources.
- Handshake negotiation selects an explicit compatible version, feature set,
  frame bounds, replay bounds, command-admission limit, and event credit limits.
- XPC validates the exact same-team app and service signing identifiers before
  protobuf decoding.
- Invalid, oversized, pre-handshake, stale-generation, and sequence-gap frames
  fail closed.
- Inbound command admission and transport queues are bounded, with reserved
  capacity for acknowledgement, cancellation, heartbeat, flow-control, and
  update-lifecycle traffic.
- Event flow control is scoped per stream and accounts for both event count and
  serialized payload bytes. Exhausting one stream cannot block another stream
  or control traffic.
- Volatile terminal output has a distinct negotiated byte window. It cannot
  consume durable-event credit or the reserved control capacity.

### Commands, cancellation, and replay

- A mutating command is acknowledged only after its idempotency key,
  deterministic fingerprint, payload, state, and outbox item commit atomically.
- Reusing a key with identical content returns the recorded receipt; reusing it
  with different content executes neither command.
- The legacy Node adapter returns a receipt for every durable command. Domain
  identifiers such as turn IDs never replace the service-generated command ID.
- Terminal input and resize remain explicitly ephemeral and bounded; they are
  never mislabeled as durable operations.
- Cancellation is a typed, durable, idempotent command with its own outbox.
  Its disposition answers whether cancellation was accepted; its independent
  lifecycle remains `accepted` or `reconciling` until an authoritative terminal
  fact makes it `terminal`. Reconnect explicitly reconciles unresolved
  cancellation IDs. Cancellation before provider start is remembered and
  suppresses later dispatch.
- Externally significant provider facts—including transcript/model output,
  tool and permission state, workflow transitions, terminal lifecycle, and
  terminal outcome—are committed to the service event journal before delivery.
- The app persists the route and event receipt before projection, applies a
  stable event identity idempotently, advances its durable cursor only after the
  projection commits, and acknowledges only that durable boundary.
- App relaunch reconstructs active routes and replays pending events without
  duplicating transcript output or tool completion.
- Terminal process identity and presentation routing are committed before
  `term_start`. The route records the stable command ID, provider lane and
  generation, presentation scope, owning conversation, and terminal tombstone,
  so relaunch deterministically restores input, resize, title, and kill routing
  to the existing service-owned terminal instead of creating a second shell.
- PTY bytes are deliberately not durable events. The service retains only a
  bounded in-memory suffix per terminal generation and sends absolute-offset
  frames on a separately credited channel. Initial attachment and reconnect use
  a snapshot frame (including the oldest retained offset); the app returns byte
  credit only after the owning terminal presentation consumes that exact frame.

### Packaging and privacy

- The signed bundle contains the helper, LaunchAgent plist, generated protocol
  manifest, pinned Node runtime, staged production dependencies, resource
  manifest, SBOM, license inventory, and matching dSYMs.
- The helper and bundled runtime resources are validated against their signed
  manifest before execution. Critical executable resources are revalidated at
  each provider launch.
- Runtime diagnostics use structured, bounded, privacy-safe fields and keyed
  fingerprints. Prompts, model output, tool payloads, credentials, environment
  variables, and user paths are not logged.

## Automated verification matrix

Run from a clean source tree after all implementation commits:

```bash
cd app
swift build --target MechanicianRuntimeProtocol
swift build --target MechanicianRuntimeCore
swift build --target MechanicianRuntimeTransport
swift build --target MechanicianRuntimeWorker
swift build --target MechanicianRuntimeServiceCore
swift build --target MechanicianRuntimeService
swift build --target Mechanician
swift test

cd ../agentd
node --check src/agentd.mjs
node --check src/ambientd.mjs
node --check src/codex-app-server.mjs
npm test

cd ..
./scripts/verify-runtime-protocol.sh
node scripts/test-runtime-resource-manifest.mjs
bash -n build-app.sh scripts/check.sh scripts/release.sh \
  scripts/stage-agentd.sh scripts/verify-runtime-service-bundle.sh
./scripts/check.sh
git diff --check
```

The final source verification result and test counts are recorded in the release
commit or pull request. A passing compile alone is not acceptance.

## Source verification evidence

The frozen Phase 1 source passed the canonical gate on 2026-07-19:

- shell syntax, property-list lint, third-party license provenance, and the Runtime Service source
  package contract passed;
- the runtime-resource manifest generation and tamper checks passed;
- the locked agentd install passed 229 of 229 Node tests and `npm audit --omit=dev` reported zero
  vulnerabilities;
- generated Swift and Node protocol sources matched the checked-in golden manifest;
- production dependency staging, registry signature/attestation checks, SBOM assertions, and all
  pinned Codex version checks passed;
- the macOS arm64 package passed 321 of 321 XCTest cases plus 25 of 25 Swift Testing cases; and
- `git diff --check` passed.

Before the canonical gate, the focused reliability matrix passed 56 of 56 tests covering atomic
route/outbox admission, crash replay, cancellation reconciliation, final terminal-output delivery,
provider replacement, window/app lifecycle, Runtime Service approval recovery, incompatible-helper
fencing, and service durability. The terminal shutdown test file also passed 20 consecutive runs
(120 cases) after its teardown was made deterministic by reaping agentd before deleting its test
configuration directory.

These results establish the deterministic source properties in this document. They do not replace
the signed installed-build checks below, which exercise launchd, code signing, real provider
subscriptions, real windows, and an installed app bundle.

The 0.10.6 transport-hardening gate additionally passed 231 of 231 Node tests, 341 of 341 XCTest
cases, and 25 of 25 Swift Testing cases. Its maximum-window fault fixture persists 2,048 events
across all four provider streams, reopens the projection database, reduces every event exactly
once, returns four coalesced acknowledgements, and proves a second recovery emits no duplicate.
Its presentation reconnect fixtures also prove account authentication survives transport loss,
that a fresh service-owned provider snapshot restores submission readiness after durable replay,
and that both an in-flight catalog request and a picker opened during reconciliation repopulate
with selectable models after the fresh readiness snapshot.

The 0.10.7 upgrade-integrity gate passed 231 of 231 Node tests, 346 of 346 XCTest cases, and 25 of
25 Swift Testing cases. Its multi-build fixtures prove that compatible-upgrade intent survives a
service restart, a replacement clears only its satisfied drain, terminals remain live but do not
block initiation, turns and workflows do block initiation, existing-activity controls continue to
the draining helper, and new durable work remains in the app outbox. Resource fixtures clone and
re-verify a complete manifest-addressed tree, mutate the source app resources, and prove both the
running generation's bytes and the following build's distinct identity. Publication additionally
requires launchd metadata, the latest authenticated XPC handshake, service bootstrap identity,
and the immutable resource-manifest hash to agree with the installed candidate.

The 0.10.8 runtime-availability gate passed 231 of 231 Node tests, 351 of 351 XCTest cases, and 25
of 25 Swift Testing cases. Its N-1 handshake fixture proves that a helper omitting the new durable
drain capability remains live through handoff; its client-state fixtures distinguish legacy live
handoff, capable durable drain, exact account-owned catalogs, disconnected durable admission, and
live-only reconnect controls. Tests write to a process-private diagnostic timeline. Build and
release scripts share an atomic artifact lock, and publication now additionally requires fresh
exact-helper evidence for authenticated snapshots, non-empty model catalogs, and completed Claude
and Codex subscription turns.

## Signed installed-build acceptance

The first Runtime Service release uses a two-stage publish so a notarized build
can be installed and exercised before the appcast and tag are published:

```bash
NO_PUSH=1 ./scripts/release.sh 0.10.0
```

Install the resulting application, then verify:

```bash
launchctl print gui/$(id -u)/ai.mechanician.runtime
./scripts/verify-installed-runtime-service.sh /Applications/Mechanician.app
./scripts/verify-installed-provider-acceptance.sh /Applications/Mechanician.app
./scripts/verify-runtime-service-bundle.sh /Applications/Mechanician.app \
  --expected-team 5YPG2C4S34
```

Dogfood all of the following before resuming publication:

- first launch and service registration;
- Claude subscription authentication and a completed turn;
- Codex Ultra quiet work, completion, interruption, and app relaunch;
- OpenAI API lane if configured;
- two windows observing the same conversation/provider stream;
- close every window during accepted work, then reopen and replay;
- enabled ambient scheduling across app quit and relaunch;
- terminal creation, input, resize, and exit;
- close and reopen the owning terminal window, confirm that the existing shell
  and its controls are restored, and confirm that the bounded output snapshot
  does not duplicate bytes;
- cancellation accepted before completion, disconnect/reconnect while it is
  reconciling, and one authoritative terminal cancellation result;
- provider failure/restart while a turn and terminal are active, with stale
  generation output ignored and each lost activity surfaced once;
- compatible helper replacement from the previous signed build; and
- replacement from each pre-durable-drain helper generation (builds 136–142) with persistent
  Claude and Codex terminals present: terminals receive one visible exit, a concurrent accepted
  turn reaches a terminal fact, and new work remains queued for the replacement; and
- launchd `parent bundle version` matching the installed app build after replacement; and
- rejection of a stale prior service after replacement.

Only after that evidence is green:

```bash
git push origin main
./scripts/release.sh 0.10.0 --resume
```

If any installed-build check fails, do not use `--resume`. Fix the source, bump
the build, and repeat the signed acceptance cycle.

## Explicit Phase 1 boundaries

Phase 1 intentionally retains **durable** service events rather than deleting
history that an offline client may still need. Although the v1 schema reserves
resume-gap and state-snapshot messages for forward compatibility, Phase 1 does
not claim cursor-expiry recovery, content-addressed snapshots, or event
compaction. Those are Program 2 migrations because safe compaction requires the
normalized product-state projection. Until then, durable ledger growth is
observable and durable events are not age-pruned.

Terminal output is the explicit exception to durable retention: raw PTY bytes
are presentation data held in bounded memory, not product history. A reconnect
receives the retained suffix as an offset-bearing snapshot; output older than
that suffix may be unavailable. Terminal identity, route, lifecycle, and final
outcome remain durable, so bounded byte loss cannot orphan or duplicate a shell.

Existing conversation, project, artifact, and task stores remain authoritative
for their disjoint user content during this migration. The app-side projection
inbox, stable event IDs, and route store prevent replay duplication; they do not
pretend those legacy stores are already one SQLite transaction with the service
ledger. Program 2 removes that split authority by moving normalized product
state behind the service writer.

Repository execution-space leases, restricted/virtualized runners, provider-
neutral workflow persistence, interactive browser state, and remote control are
also later programs. Their absence does not weaken the Phase 1 single-runtime
authority, but none should be described as completed by this release.
