# ADR-001: Per-user Runtime Service

> **Superseded. Archived history. Do not implement anything in this file.**
>
> The Runtime Service described here was built, shipped, and reverted on 2026-07-20. It never
> delivered the concurrent-write safety it was designed for, and splitting one process lifetime
> into three introduced a bug class that took days to drain. See
> [the history index](../README.md) for what went wrong and the rules that came out of it.
>
> What replaced it: nothing. The app talks directly to `agentd` over newline-delimited JSON on
> stdio, which is the arrangement this ADR proposed to remove. That protocol is documented in
> [docs/architecture/AGENTD-PROTOCOL.md](../../architecture/AGENTD-PROTOCOL.md). The persistence
> design that did ship, an in-process SQLite authority rather than a service-owned one, is in
> [docs/architecture/STORAGE-AND-PERSISTENCE.md](../../architecture/STORAGE-AND-PERSISTENCE.md).

- Original status: Accepted
- Date: 2026-07-19
- Owners: Mechanician runtime and macOS application maintainers
- Related: [ADR-002](ADR-002-runtime-protocol.md),
  [architecture implementation plan](../ARCHITECTURE-IMPLEMENTATION-PLAN.md)
  (both also archived, both also superseded)

## Context

Mechanician currently creates provider runtimes from application-window state.
That made the first implementation direct, but it gives a UI lifecycle event too
much authority: closing a window or quitting the app can terminate work, opening
multiple windows can create competing provider processes, and a UI process
failure can discard the only live connection to an accepted provider turn.

The product already contains work whose lifetime is not a window lifetime:
provider turns, workflows, ambient schedules, terminal sessions, approvals,
repository coordination, and recovery. A reliable implementation needs one
per-user owner for that work and a versioned boundary between it and any number
of UI clients.

Mechanician targets macOS 26 or newer. That allows the implementation to use the
Swift XPC APIs introduced in macOS 26, including `XPCPeerRequirement`, rather
than maintaining a weaker compatibility path for older systems.

This ADR decides process ownership, security boundaries, lifecycle, migration,
and the minimum persistence that must exist before the larger Program 2 data
model lands. Wire semantics are decided in ADR-002.

## Decision

Mechanician will bundle a per-user LaunchAgent named
`MechanicianRuntimeService`, registered by the containing application with
`SMAppService`. The service is the sole runtime authority for a signed-in macOS
user. Every Mechanician window is an authenticated client of that authority.

The service owns:

- provider-process creation, health, restart, generation, and shutdown;
- Claude, Codex, and OpenAI session and turn lifecycles;
- all accepted runtime commands and their idempotent outcomes;
- workflows, ambient schedules, and work that may outlive every window;
- repository identities, execution spaces, and writer leases as those modules
  are introduced;
- runtime persistence and the only write connection to runtime databases;
- credential retrieval and delivery to provider processes;
- durable event publication, replay, and crash reconciliation; and
- terminal processes whose requested lifetime extends beyond a window.

The application owns:

- windows, view state, presentation, and user interaction;
- local rendering caches that can be rebuilt from service state;
- explicit user consent and confirmation surfaces;
- macOS capabilities whose TCC grant or UI contract belongs to the foreground
  application; and
- registration, update coordination, health reporting, and recovery UI for the
  bundled service.

The Node runtime and `agentd` remain bundled implementation details supervised
by the service. Node is not a second authority. `agentd` becomes a provider and
tool adapter reached only through service-owned interfaces.

### Anthropic subscription policy is unchanged

This architecture does **not** remove, narrow, reinterpret, or otherwise change
Mechanician's current support for Anthropic subscription authentication. The
service hosts the same supported subscription path through the bundled
Anthropic SDK/CLI integration. It does not convert subscription users to API-key
billing, export their credentials to UI clients, or add a policy gate that did
not previously exist. Authentication implementation may be isolated and
secured more strongly, but product policy remains unchanged.

## Single authority and ownership

There must never be both a service-owned provider pool and a window-owned
provider pool for the same user profile.

The service records a monotonically increasing `authority_epoch` in its control
ledger and holds the runtime-authority lock while active. Every command, event,
provider generation, and client handshake names that epoch. A process that
cannot prove it owns the current epoch cannot start a provider or mutate runtime
state.

During migration, the legacy in-app runtime and the new service are selected by
one persisted authority mode:

```text
legacyDirect | service | migrationBlocked
```

Mode transitions occur only while no accepted command is executing and after a
durable checkpoint. They are compare-and-swap operations against the current
epoch. A connection failure never silently changes the mode. In particular, a
UI client must not start a direct provider merely because the service is slow,
upgrading, or temporarily unreachable.

Provider pools are keyed by provider lane, authentication identity, and any
provider isolation boundary—not by window. Conversation and turn ownership is
stored in the service. Multiple windows subscribe to the same stream and see
the same provider state without creating duplicate processes.

## Packaging and registration

The signed application bundle contains:

```text
Mechanician.app/
  Contents/
    MacOS/Mechanician
    Helpers/MechanicianRuntimeService
    Library/LaunchAgents/ai.mechanician.runtime.plist
```

The LaunchAgent property list uses `BundleProgram` with a bundle-relative path
and publishes a per-user Mach service. It is not copied into
`~/Library/LaunchAgents`, and no privileged installer is required. The main app
registers it with:

```swift
SMAppService.agent(
    plistName: "ai.mechanician.runtime.plist"
)
```

The registration coordinator treats `SMAppService.Status` as product state:

- `enabled`: connect and perform the protocol handshake;
- `notRegistered`: register, then connect;
- `requiresApproval`: explain why the service is required and offer to open
  System Settings with `SMAppService.openSystemSettingsLoginItems()`;
- `notFound`: report a damaged or incorrectly packaged application and offer a
  reinstall, never a direct-runtime fallback; and
- registration or signature error: enter a diagnosable blocked state.

The app may call `register()` idempotently, treating the already-registered
error as success only after status and a signed handshake confirm the expected
service. Registration is performed once for each macOS user who runs the app.

The service is demand-launched by its Mach service and may be bootstrapped when
registered. A user disabling its Login Items switch is an explicit revocation;
Mechanician explains the consequence rather than working around it.

## Mutual client authentication

Authentication is enforced by XPC before application messages are decoded.
Both directions fail closed.

The service listener accepts only a peer satisfying:

```swift
XPCPeerRequirement.isFromSameTeam(
    andMatchesSigningIdentifier: "ai.mechanician.app"
)
```

The app creates its Mach-service `XPCSession` with a peer requirement for the
service's exact signing identifier:

```swift
XPCPeerRequirement.isFromSameTeam(
    andMatchesSigningIdentifier: "ai.mechanician.runtime-service"
)
```

The production listener and session use the macOS 26 initializers that take a
peer requirement. An audit token is retained in bounded security diagnostics
and used to confirm the expected per-user session identity, but an audit-token
PID or UID check is not a substitute for the signing requirement. Messages from
an invalid peer are rejected before handshake or protobuf parsing.

Development builds use a separately named development Mach service and an
explicit development signing configuration. Production never weakens its
requirement to accept unsigned or merely same-user clients.

The established XPC session is bidirectional. Service-to-app capability
requests travel on that authenticated session, so a second unauthenticated
callback listener is not introduced.

## TCC capability broker

Moving runtime authority out of the app must not cause a background helper to
silently inherit or prompt for unrelated UI permissions. The main application
is the capability broker for operations that are inherently foreground- or
TCC-bound, including user-facing screen capture, accessibility-driven computer
control, microphone capture, and UI-mediated Apple Events.

The service sends a typed `CapabilityRequest` containing:

- the durable command and turn identity;
- a narrow capability kind and bounded arguments;
- the expected authority and provider generation;
- an expiry and single-use nonce; and
- the reason that can be shown to the user.

The app verifies that the request belongs to an active service generation,
performs any required consent interaction, and returns a typed result. Large
results use the blob protocol in ADR-002. The service validates the nonce,
generation, result type, byte limits, and content digest before applying it.

Rules:

- The broker exposes capabilities, not arbitrary code execution.
- A background request cannot synthesize consent or promote itself to a broader
  capability.
- If no eligible UI client exists, work enters `waitingForUICapability` and is
  durably resumable. It does not fail open.
- Closing the window that initiated the turn does not discard the request;
  another authenticated active window may present it after the service assigns
  presentation ownership.
- Exactly one client receives presentation ownership at a time. Client loss
  revokes that lease and allows reassignment.
- Credentials and provider refresh tokens remain service-owned and are never
  returned through the capability broker.

Longer-term restricted or virtualized runners remain separate execution
capabilities. They do not collapse into the foreground-app broker.

## Minimum durable control ledger

Program 2 still owns the complete transactional product ledger and normalized
projections. Phase 1 pulls forward the minimum durable control ledger required
to make the service boundary truthful.

The service is the sole writer to a SQLite database in its per-user Application
Support container. It uses WAL, foreign keys, a bounded busy timeout, and full
synchronization for acknowledged control state. At minimum it contains:

```text
runtime_metadata
authority_epochs
client_sessions
commands
command_outcomes
event_streams
events
subscriber_cursors
provider_generations
outbox
schema_migrations
```

The ledger persists an accepted mutating command and its idempotency key before
external execution, persists externally significant events before publishing
them, and records terminal outcomes atomically. It is sufficient to recover
command ownership, reject duplicate effects, reconstruct replay, and reconcile
provider generations after a service crash.

It is not a second copy of user content. Until a Program 2 projection becomes
authoritative, existing user-state files remain authoritative for that
disjoint content, but all access to them moves behind service repository
interfaces once service mode is active. UI clients do not write those files.
Shadow imports may compare state, but may not become a second writer.

## Lifecycle and idle policy

Window connection and work ownership are independent:

- Closing a window unsubscribes that client; it does not stop provider turns,
  workflows, terminals, or ambient runs.
- Quitting the UI has the same default effect. Cancellation requires an
  explicit Stop action addressed to the service.
- Relaunching the UI negotiates a new session and replays from its durable
  cursors.
- Service crashes are handled by launchd restart followed by ledger and
  provider reconciliation.

The service exits only through an explicit idle decision. It is idle when all
of the following are true:

- no accepted command, provider turn, workflow, terminal, or capability request
  is active or recoverable;
- the durable outbox is empty;
- no enabled ambient schedule requires the service to retain scheduling
  responsibility; and
- no migration, checkpoint, upgrade handoff, or recovery is pending.

Client count alone is not an idle criterion. After a configurable grace period,
an idle service checkpoints, closes provider processes, and exits normally.
Mach-service demand starts it again. Enabled dynamic ambient schedules keep the
service alive until a later design provides an equally reliable launchd wakeup
contract.

## Updates and re-registration

An app update can leave an older service process running while a newer UI starts.
This is a normal protocol state, not a reason to kill work.

At connection, both peers exchange build identity, protocol range, schema hash,
authority epoch, ledger schema, and feature capabilities. Then:

1. If protocol ranges overlap, the new UI continues using the negotiated
   version. The service reports `upgradePending` when its embedded build differs.
2. The service stops accepting work that requires unavailable features, but
   existing compatible work continues.
3. When durable work is idle, the service checkpoints, drains its outbox, and
   exits for replacement. The app verifies `SMAppService` status and the bundle
   identity, re-registering only when status or path attribution requires it.
4. If unregister/register is necessary, it occurs only after the checkpoint;
   `unregister()` is treated as terminating the running LaunchAgent.
5. The new service must acquire a new authority epoch and reconcile the ledger
   before accepting commands.

If protocol ranges do not overlap, the UI enters `updateRequired` and does not
send commands. It may monitor a pre-existing turn through a deliberately
retained compatibility decoder, but it must never restart the provider under a
second authority. A force-upgrade option explicitly warns about active work and
first creates a recovery checkpoint.

Every release build validates that the LaunchAgent plist, executable location,
Mach-service label, signing identifiers, entitlements, and designated
requirements match. A signed-package integration test installs two consecutive
builds and verifies registration, live compatible handoff, idle replacement,
and rejection of the old service afterward.

## Failure and degraded states

The app models these states explicitly:

| State | Meaning | Allowed behavior |
|---|---|---|
| `starting` | Service is registered or demand-launching | Bounded reconnect; no direct runtime |
| `healthy` | Authenticated, negotiated, ledger recovered | Normal operation |
| `requiresApproval` | User disabled or has not approved the agent | Explain and open Login Items settings |
| `packageInvalid` | Plist, executable, or signature is missing/invalid | Block runtime and offer reinstall/diagnostics |
| `authenticationRejected` | Peer requirement failed | Block; security diagnostic only |
| `protocolIncompatible` | No compatible version | Require compatible app/service update |
| `recovering` | Ledger/provider reconciliation in progress | Read-only status; queue nothing implicitly |
| `upgradePending` | Compatible old service is finishing work | Continue compatible work; defer new features |
| `storageDegraded` | Control ledger cannot safely commit | Read-only recovery; do not acknowledge mutations |
| `backpressured` | Client or provider exceeded negotiated flow control | Slow/detach client; preserve durable work |
| `migrationBlocked` | Authority transition failed validation | Keep last valid authority; require explicit repair |

No degraded state silently starts a window-owned provider. Errors include a
stable code, recovery action, redacted diagnostic context, and whether retry is
safe.

## Migration and rollback

Migration is staged and observable:

1. **Interface extraction.** Existing direct behavior moves behind
   `RuntimeClient`, provider supervisor, persistence, capability, and transport
   interfaces without changing authority.
2. **Shadow service.** The signed service registers, authenticates, negotiates,
   and validates shadow reads and protocol fixtures. It does not execute
   commands or start providers.
3. **Controlled authority cutover.** With all work idle, create backups and a
   manifest, claim a new authority epoch, switch the persisted mode to
   `service`, then allow the service to start providers.
4. **Default service.** New installations and migrated profiles use service
   authority. The legacy path remains compiled only for the defined rollback
   window and cannot auto-activate.
5. **Removal.** After at least two compatible releases and successful restore,
   update, and fault-injection evidence, remove direct provider ownership from
   the app.

Rollback during the compatibility window requires idle work, a durable service
checkpoint, validated export of any state the legacy build understands, release
of the authority lock, and an atomic epoch/mode transition. If state cannot be
represented without loss, rollback is blocked and the user is told why. A
crash, XPC interruption, or denied registration is never sufficient to trigger
automatic rollback.

## Rejected alternatives

### Keep one runtime per window

Rejected because UI ownership cannot satisfy survival, shared-session, replay,
or single-writer requirements.

### Put the singleton in the main app process

Rejected because quitting or crashing the UI still terminates durable work and
scheduled tasks.

### Use an XPC Service embedded in the app instead of a LaunchAgent

Rejected because its lifecycle is optimized for short, on-demand helper work,
not a per-user authority that owns schedules and long provider turns.

### Install an unmanaged `~/Library/LaunchAgents` plist

Rejected because `SMAppService` provides signed bundle attribution, approval
status, update behavior, and System Settings integration without copying
mutable launch configuration into the user's home directory.

### Fall back to direct execution whenever XPC fails

Rejected because it recreates dual authority precisely during failures, when
duplicate effects are most dangerous.

## Consequences

Positive consequences:

- running work survives window and UI lifecycles;
- multiple windows share provider and event state;
- process, credential, and write authority become auditable;
- crash recovery and updates have one owner; and
- UI/TCC concerns remain in the foreground process without owning runtime work.

Costs:

- the app now ships and tests an additional signed executable and LaunchAgent
  registration lifecycle;
- every runtime operation crosses a versioned asynchronous boundary;
- a minimal durable ledger is required earlier than the full Program 2 schema;
- updates require compatibility and handoff engineering; and
- UI code must tolerate replay, disconnection, and service degraded states.

## Acceptance criteria

This ADR is implemented only when automated and signed-package tests prove:

- two or more windows use one provider process/session and receive one ordered
  event stream;
- closing every window and quitting the app do not terminate accepted durable
  work;
- app relaunch resumes from durable cursors without duplicate effects or output;
- service crash and launchd restart reconcile accepted commands and provider
  generations;
- app and service reject wrong-team, wrong-identifier, unsigned, malformed,
  oversized, and pre-handshake peers/messages;
- denied LaunchAgent approval produces an actionable state, not hidden fallback;
- no legacy and service provider authority can coexist;
- TCC-bound work pauses safely with no UI and resumes through exactly one
  authenticated capability broker;
- compatible updates drain and hand off without killing work, while incompatible
  updates fail explicitly;
- storage failure prevents mutation acknowledgement; and
- the Anthropic subscription authentication path continues to work unchanged.

## References

- [Apple: SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice)
- [Apple: Updating helper executables from earlier versions of macOS](https://developer.apple.com/documentation/servicemanagement/updating-helper-executables-from-earlier-versions-of-macos)
- [Apple: XPC](https://developer.apple.com/documentation/xpc)
