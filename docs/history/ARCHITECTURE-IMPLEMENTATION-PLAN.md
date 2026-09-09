# Mechanician architecture implementation plan

> **Superseded. Archived history. Do not implement anything in this file.**
>
> Programs 1 through 3 describe the Runtime Service, which was built, shipped, and reverted on
> 2026-07-20. Read [the history index](README.md) before you read any of it.
>
> Three specific corrections to what follows:
>
> - Program 0 (Codex lifecycle reconciliation) is the part that survived. `codex-lifecycle.mjs` is
>   in the tree and was untouched by both the service and the revert, which is itself evidence that
>   the service was not load-bearing for it. Its shipped behaviour is described in
>   [docs/architecture/BACKGROUND-WORK.md](../architecture/BACKGROUND-WORK.md).
> - Program 2 wanted a service or daemon to own durable state. A SQLite authority did ship, but in
>   the app's own process (`LibraryAuthorityRepository`), with no service and no daemon. See
>   [docs/architecture/STORAGE-AND-PERSISTENCE.md](../architecture/STORAGE-AND-PERSISTENCE.md).
> - Program 3's automatic managed worktrees were dismissed separately, on their own merits, and are
>   not planned.
>
> The shipped process boundaries and wire format are in
> [docs/architecture/OVERVIEW.md](../architecture/OVERVIEW.md) and
> [docs/architecture/AGENTD-PROTOCOL.md](../architecture/AGENTD-PROTOCOL.md).

Original status: approved direction; Program 0 engineering implementation complete.

This document turns the pre-release architecture review into a dependency-ordered
engineering program. It deliberately favors durable foundations over patches
that would be replaced by the next phase.

## Decisions and invariants

- Keep the current Anthropic subscription policy. Architecture changes may
  isolate credentials and provider processes more strongly, but must not remove
  or reinterpret the supported subscription path.
- Keep Node as a bundled implementation detail. A user installing the signed app
  must not install Node, Git, Xcode, or Command Line Tools.
- Continue targeting Apple Silicon and macOS 26 or newer.
- Preserve the locked-down static HTML preview. Interactive browsing is a
  separate subsystem with a separate data store and permission model.
- Never terminate a quiet Codex Ultra turn merely because it is slow. Silence
  triggers an authoritative state query, not a blind timeout.
- Provider-native subagents are visible provider activity, not Mechanician's
  durable workflow scheduler.
- Do not silently commit, reset, delete, or merge a user's working tree.
- Do not invent a cryptographic protocol for remote access.

## Release gates

The complete roadmap is too large to block publication of a 0.x source tree.
The next binary release is nevertheless gated by two reliability properties:

1. Codex Ultra lifecycle reconciliation: no provider turn may remain permanently
   running after it completed, failed, was interrupted, disappeared, or survived
   an App Server restart.
2. Concurrent-write safety: independent writers must never mutate the same
   working directory without an explicit execution-space policy.

## Target system

```text
Mechanician windows ── versioned XPC ──> per-user Runtime Service
                                             │
                 ┌───────────────────────────┼──────────────────────────┐
                 │                           │                          │
          SQLite event ledger       Repository coordinator      Provider supervisor
                 │                    and worktree leases         ├─ Claude / Node
          Workflow scheduler                 │                   ├─ Codex App Server
                 │                     bundled pinned Git         └─ OpenAI API
                 │
          Credential and capability broker
                 ├─ trusted host runner
                 ├─ restricted local runner
                 └─ virtualized Linux runner
```

The Runtime Service becomes the one per-user authority for provider sessions,
turns, durable commands, workflows, ambient tasks, repository ownership,
credentials, and recovery. Windows become clients. Closing a window must not
implicitly kill work, and opening another window must not create a competing
runtime authority.

## Program 0: Codex Ultra lifecycle reliability

Priority: P0, release blocking

### Current evidence

Mechanician currently records an application turn before Codex has
authoritatively accepted and started the provider turn. After `turn/start`, the
adapter waits for a terminal notification. Recent logs contain two cases where:

1. Mechanician believed a turn was active.
2. an interrupt was sent;
3. Codex replied that there was no active turn;
4. Mechanician retained its active-turn state; and
5. the interrupt watchdog restarted App Server.

That proves a local/provider ownership mismatch, but it does not yet prove that
Ultra is causal: the current logs omit effort, provider thread ID, provider turn
ID, and authoritative thread state.

The pinned App Server protocol exposes the inputs needed for reconciliation:
`turn/started`, `turn/completed`, `thread/status/changed`, and
`thread/read` with turns included.

### 0.1 Privacy-safe lifecycle trace

Record a bounded structured trace containing:

- runtime instance and process generation;
- client command and correlation IDs;
- a non-reversible conversation identifier;
- provider lane and authentication mode;
- bundled Codex version and generated-schema hash;
- model and reasoning effort, including `ultra`;
- provider thread and turn IDs;
- method or notification name;
- previous and next local state;
- provider status returned by reconciliation;
- monotonic and wall-clock timestamps; and
- process exit or restart reason.

Prompts, output, tool payloads, environment variables, and credentials are
excluded. Add a user-controlled redacted diagnostics export.

### 0.2 Exact protocol conformance

- Generate JSON schemas from the pinned bundled Codex binary in CI.
- Store the generated schema hash with the build.
- Validate or generate adapter types from those schemas.
- Fail CI when the binary changes without a reviewed schema update.
- Record adapter capabilities and protocol version during startup.

### 0.3 Explicit state machine

```text
queued
  -> providerStarting
  -> providerActive
       <-> waitingForApproval
       <-> waitingForUserInput
       <-> reconciling
  -> completed | failed | interrupted | recoverableOrphan
```

Rules:

- Do not display provider-active until `turn/start` succeeds and a provider turn
  identity is known.
- Key terminal transitions by provider turn ID and make them idempotent.
- Reject stale events from an older provider-process generation.
- Persist partial output before terminalizing.
- A missing notification must not leave the UI active forever.

### 0.4 Reconciliation

On activity silence:

1. enter `reconciling` without interrupting;
2. call `thread/read(includeTurns: true)`;
3. if the expected turn is in progress, remain active and surface whether Codex
   is working, awaiting approval, or awaiting input;
4. if the turn is terminal, synthesize the same idempotent terminal transition;
5. if the thread is idle and the expected turn is absent, preserve partial output
   and mark a recoverable orphan; and
6. only after bounded reconciliation requests fail and the process is
   unresponsive, restart that provider lane and reconcile again.

An interrupt response of "no active turn" starts reconciliation immediately.

### 0.5 Fault-injection tests

Build a deterministic fake App Server capable of:

- dropping, duplicating, and reordering notifications;
- returning `turn/start` without `turn/started`;
- returning a terminal before the start response is consumed;
- reporting no active turn during interrupt;
- exiting between response and notification;
- remaining legitimately quiet; and
- changing provider generation mid-turn.

Run the matrix across Ultra and lower efforts, fresh and resumed threads,
tool-free and tool-heavy turns, approvals, subagents, steering, interruption,
window closure, concurrent conversations, network loss, and App Server restart.

### Acceptance

- No accepted turn remains indefinitely active.
- Local/provider disagreement resolves within a bounded probe interval.
- Quiet Ultra work is never killed solely for being quiet.
- Each accepted provider turn reaches exactly one local terminal state.
- Recovery does not duplicate transcript output or tool completion.
- Diagnostics distinguish provider latency, approval wait, notification loss,
  process loss, and reducer failure.

### Completion evidence (2026-07-18)

- A provider-identity-aware reducer is the single lifecycle authority. It enforces legal phases,
  rejects stale process/thread/turn identities atomically, owns bounded reconciliation policy, and
  permits exactly one terminal transition.
- `thread/read(includeTurns: true)` recovers missing terminal notifications, preserves quiet work
  and provider wait states, bounds ownership disagreement, creates recoverable orphans, and restarts
  only after repeated invalid or unanswered probes.
- The fake App Server exercises dropped, duplicate, reordered, early, and oversized events;
  response/notification process exits; interrupt mismatch; quiet Ultra; wait states; network-like
  request loss; stale events; resumed threads; tools; approvals; subagents; steering; window/control
  closure; concurrency; and App Server replacement.
- A seeded reducer soak covers 100,000 accepted turns across 13 failure/success scenarios, Ultra and
  lower effort, fresh and resumed ownership, and tool-free/tool-heavy metadata. Every turn reaches
  one terminal phase; no quiet turn is killed for silence.
- Settings → Advanced provides a bounded, defense-in-depth redacted diagnostics export. See
  [CODEX-LIFECYCLE-DIAGNOSTICS.md](../CODEX-LIFECYCLE-DIAGNOSTICS.md).
- The external-provider dogfood checklist remains a deliberate release-candidate validation step:
  it is human-triggered because it consumes the user's subscription. It is not an unimplemented
  lifecycle mechanism or an automated CI dependency.

## Program 1: versioned protocol and per-user Runtime Service

Priority: P0 foundation

Bundle a `MechanicianRuntimeService` LaunchAgent registered with `SMAppService`.
It owns provider supervision, database writes, workflows, ambient scheduling,
repositories, worktrees, credential delivery, and crash recovery.

Validate XPC clients by audit token and Mechanician's signing requirement.
Retain running and scheduled work when UI windows close. Apply an explicit idle
shutdown policy only when no durable work remains.

Use a generated schema-first protocol, preferably Protocol Buffers with
SwiftProtobuf and generated Node types. Every envelope carries:

```text
protocolVersion
messageId
correlationId
streamId
sequence
sentAt
oneof payload
```

The protocol requires handshake negotiation, bounded frames, idempotency keys,
resume cursors, cancellation semantics, stale-generation rejection,
backpressure, and file-descriptor or content-hash transfer for large blobs.

Split Swift into protocol, client, service, persistence, repository, workflow,
security, and provider-model modules. Split agentd into transport, provider
adapters, process supervision, tools, and terminal modules. Move existing
behavior behind interfaces before changing it.

Acceptance:

- Multiple windows share one provider session and event stream.
- Closing all windows does not kill durable work.
- Relaunch replays missed events exactly once.
- Protocol incompatibility fails explicitly.
- Invalid, unauthenticated, oversized, or stale-generation frames are rejected.

## Program 2: transactional ledger and migration

Priority: P0 foundation

Bundle a pinned SQLite release at 3.51.3 or newer. The Runtime Service is the
sole writer. Use WAL, foreign keys, controlled checkpoints, bounded busy
timeouts, and full synchronization for acknowledged user state.

Use a transactional event journal plus normalized projections:

```text
events, commands, outbox
projects, conversations, messages, turns, tool_calls
permission_decisions, provider_sessions
workflow_definitions, workflow_runs, workflow_nodes, workflow_attempts
execution_spaces, writer_leases
artifacts, artifact_versions, blobs
ambient_tasks, ambient_runs, schema_migrations
```

Each mutating transaction validates an idempotency key, appends an immutable
event, updates projections, enqueues external work, and commits atomically.
Persist outbound commands before sending them and provider events before
publishing them to clients. Store large data as content-addressed blobs.

Migration:

1. keep JSON authoritative while importing into a shadow database;
2. record source path, length, digest, count, and validation result;
3. compare projections continuously and expose discrepancies;
4. create an immutable manifest and backup before activation;
5. perform a final validated import and atomically switch authority;
6. maintain compatibility JSON export through a defined rollback window; and
7. never delete or silently skip a source file.

Acceptance includes process and machine termination at every transaction
boundary, idempotent command replay, quarantine of corrupt input, restore tests,
and exact stable-ID/blob preservation.

## Program 3: worktree-native execution spaces

Priority: P0 concurrent-write safety

Every coding turn or durable workflow node binds to an `ExecutionSpace`:

```text
id, projectId, repositoryCommonDir, workingPath
kind: shared | managedWorktree | virtualMachine
baseRef, branchRef, headOID, lifecycle, owner, securityProfile
```

A generation-based `WriterLease` names the execution space, writer, acquisition
time, expiry, and heartbeat. The Repository Coordinator alone creates/removes
managed worktrees and grants writer leases.

Bundle a pinned, signed Git toolchain for complete worktree, submodule, filter,
credential-helper, and LFS behavior. Keep the existing no-install read path for
status and diff display, both behind a `GitBackend` interface.

Defaults:

- new git-backed coding conversations receive a managed worktree;
- only one writer owns a shared working tree;
- workflow writers receive separate worktrees;
- shared mode is explicit and visibly owned;
- active worktrees are Git-locked with a reason.

Never create a hidden commit from a dirty source tree. Offer explicit choices:
base on HEAD, create a recorded patch snapshot, acquire an exclusive shared-tree
lease, or cancel.

Lifecycle:

```text
creating -> active -> readyForReview -> integrated | exported
         -> archived -> cleanupEligible
```

Never remove dirty, unmerged, unpublished, leased, or live-workflow worktrees.
On startup reconcile the ledger, filesystem, refs, and
`git worktree list --porcelain -z`; repair moved worktrees when appropriate.

Acceptance covers crash recovery, concurrent writers, non-destructive cleanup,
submodules, LFS, sparse checkout, symlinks, nested repositories, case
collisions, moved roots, and user adoption/export of a managed worktree.

## Program 4: provider-neutral durable workflows

Priority: P1

Provider subagents stay visible as provider activity. A durable Mechanician
workflow launches each durable agent node as its own provider turn and records
its external identity.

An immutable, versioned workflow definition is a DAG of agent, tool, test,
approval, human-input, condition, fan-out, and merge nodes. Persist workflow
runs, node runs, attempts, content-addressed inputs/outputs, execution spaces,
provider IDs, retry classifications, idempotency keys, and causation.

```text
queued -> leasing -> running
       -> waitingForApproval | waitingForInput | waitingForRetry
       -> succeeded | failed | cancelled | blocked
```

The scheduler advances state in the transaction that acquires a lease. Retry
only classified transient failures. Side-effecting nodes require idempotency or
reconciliation. Cancellation is hierarchical and durable. Restart reattaches to
provider turns when possible and preserves uncertain attempts for recovery
rather than rerunning them blindly.

Acceptance includes termination at every node state, 50-way fan-out under
resource limits, exactly-once side effects, durable approvals, hierarchical
cancellation, and historical definition reproducibility.

## Program 5: credential broker and execution isolation

Priority: P1 security

The Anthropic subscription and configured permission behavior remain intact.
If a user requests `bypassPermissions`, the trusted-host profile preserves its
meaning rather than silently downgrading it.

Move Keychain access to a Swift Security.framework broker. Node must not invoke
the `security` command. Deliver provider and MCP credentials by one-shot file
descriptor or authenticated broker channel, scoped to one child and excluded
from disk, logs, diagnostics, and broad process environments.

Execution profiles:

1. Trusted host: current host capability, explicit and audited.
2. Restricted local: App-Sandboxed XPC runner with security-scoped project
   bookmarks, no Keychain access, bounded resources, and brokered network.
3. Strong isolated VM: a signed Linux image under Virtualization.framework,
   copy-on-write per execution space, VirtioFS workspace, network disabled by
   default or allowlisted through a proxy, and a minimal versioned guest agent.

Apple automation and computer control remain separate host capabilities and
cannot be reached silently from a VM.

Test symlink and path escape, TOCTOU replacement, approval replay, environment
and crash-dump leakage, network smuggling, child-process escape, stale
bookmarks, malicious repositories, and compromised provider adapters.

## Program 6: interactive browser and review lifecycle

Priority: P2

Keep `SafeHTMLPreview` nonpersistent and without script, network, frames, or
forms. Add a distinct `BrowserSession` subsystem with isolated per-project or
ephemeral `WKWebsiteDataStore` profiles, controlled navigation, localhost
preview, viewport presets, screenshots, console capture, and DOM/accessibility
inspection.

Expose structured browser actions. Raw JavaScript is a separately permissioned
expert capability, not the default API.

Persist review sessions and comments anchored by base/head object IDs, path,
side, line, context digest, and execution-space ID. Relocate anchors
deterministically after diff changes and surface ambiguity. Support base-branch
comparison, inline feedback to agents, stage/commit integration, CI status, and
issue-to-worktree-to-branch-to-pull-request lifecycle through a `VCSProvider`
interface. GitHub is the first provider; credentials stay in the broker.

## Program 7: secure remote and mobile control

Priority: P3

Build a native iOS companion from the shared generated protocol. The Mac Runtime
Service remains authoritative. Pair by QR code and explicit approval; keep
device identity in Keychain/Secure Enclave. Use an audited MLS implementation
based on RFC 9420. The relay stores only opaque encrypted envelopes, and APNs
contains only opaque wake metadata.

Initial capabilities are view, steer, answer, stop, and biometric approval of a
precisely described pending action. Remote clients cannot create global grants
or enable bypass mode by default. Bind every approval to the exact workspace,
tool, normalized argument/content digest, sequence, and expiry.

Acceptance includes relay compromise, replay, revocation, key rotation,
lost-device recovery, offline convergence, and independent cryptographic review.

## Cross-cutting definition of done

Every milestone includes:

- unit and integration tests;
- generated protocol/schema checks;
- crash and deterministic fault injection;
- migration and rollback tests where applicable;
- security negative tests;
- performance and soak testing;
- privacy-safe diagnostics;
- visible user recovery behavior; and
- architecture decision records and public documentation.

The Runtime Service enforces global and per-provider concurrency, memory and
output budgets, workflow/tool deadlines, browser limits, and worktree/VM storage
quotas.

## Dependency-ordered delivery

| Phase | Deliverable | Solo estimate |
| --- | --- | ---: |
| 0 | Codex Ultra diagnostics, schema conformance, reconciliation, fault injection | 2–3 weeks |
| 1 | Runtime protocol and per-user service | 6–9 weeks |
| 2 | SQLite ledger and validated migration | 6–9 weeks |
| 3 | Execution spaces, bundled Git, worktrees, writer leases | 6–9 weeks |
| 4 | Durable workflow engine | 8–12 weeks |
| 5A | Credential broker and restricted local runner | 8–12 weeks |
| 5B | Virtualized untrusted runner | 8–12 weeks |
| 6 | Browser sessions, review model, GitHub lifecycle | 8–12 weeks |
| 7 | Secure relay and iOS companion | 12–18 weeks |

The complete program is approximately 12–18 months for one experienced
engineer, including migration, hardening, and production validation.

## Immediate backlog

Codex release gate:

- ULTRA-001: structured privacy-safe lifecycle diagnostics. **Complete.**
- ULTRA-002: generate and validate the pinned App Server schema in CI. **Complete.**
- ULTRA-003: isolate the Codex adapter behind a tested state machine. **Complete.**
- ULTRA-004: consume start, completion, and thread-status events. **Complete.**
- ULTRA-005: implement authoritative `thread/read` reconciliation. **Complete.**
- ULTRA-006: reconcile immediately after "no active turn." **Complete.**
- ULTRA-007: deterministic fake App Server and failure matrix. **Complete.**
- ULTRA-008: Ultra soak and diagnostic review. **Automated 100,000-turn soak complete;
  human-controlled external-provider checklist documented for each release candidate.**

Concurrent-write release gate:

- SPACE-001: execution-space and writer-lease schemas.
- SPACE-002: Repository Coordinator and invariant tests.
- SPACE-003: pinned Git distribution.
- SPACE-004: managed worktree create/reconcile/repair.
- SPACE-005: bind every writer to an execution space.
- SPACE-006: dirty-source patch snapshots.
- SPACE-007: review and integration lifecycle.
- SPACE-008: non-destructive cleanup and recovery.

Architecture decision records:

- ADR-001: Runtime Service ownership and lifecycle.
- ADR-002: versioned runtime protocol.
- ADR-003: transactional ledger and migration.
- ADR-004: execution spaces and writer leases.
- ADR-005: provider activity versus durable workflows.
- ADR-006: trusted, restricted, and VM execution profiles.
- ADR-007: static preview versus interactive browser.
- ADR-008: remote trust and encryption.

## Explicitly rejected shortcuts

- fixed silence timeout for Ultra;
- restarting every provider lane for one inconsistent turn;
- treating UI animation state as provider truth;
- an in-process mutex as the final repository-isolation design;
- hidden commits from a dirty user tree;
- JSON projections as a durable scheduler;
- calling provider subagents durable without recovery identifiers;
- broad Keychain access from Node;
- claiming App Sandbox alone contains arbitrary shell execution;
- enabling script or network access in `SafeHTMLPreview`;
- custom end-to-end cryptography;
- provider-specific experimental transport as the remote foundation; and
- changing or removing the Anthropic subscription policy.

## References

- [Codex App Server](https://learn.chatgpt.com/docs/app-server.md)
- [Git worktree](https://git-scm.com/docs/git-worktree)
- [SQLite write-ahead logging](https://www.sqlite.org/wal.html)
- [SQLite atomic commit](https://www.sqlite.org/atomiccommit.html)
- [Apple XPC](https://developer.apple.com/documentation/xpc)
- [SMAppService LaunchAgent](https://developer.apple.com/documentation/servicemanagement/smappservice/agent%28plistname%3A%29)
- [App Sandbox](https://developer.apple.com/documentation/xcode/configuring-the-macos-app-sandbox)
- [Security-scoped file access](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox)
- [Virtualization.framework](https://developer.apple.com/documentation/virtualization)
- [WKWebsiteDataStore](https://developer.apple.com/documentation/webkit/wkwebsitedatastore)
- [MLS RFC 9420](https://www.rfc-editor.org/info/rfc9420/)
