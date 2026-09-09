# ADR-002: Versioned Runtime Protocol

> **Superseded. Archived history. Do not implement anything in this file.**
>
> This protobuf-over-XPC protocol was written for the Runtime Service in
> [ADR-001](ADR-001-runtime-service.md), which was built, shipped, and reverted on 2026-07-20.
> The generated protocol tree, the `.proto` files, and the XPC transport were all removed with it.
> Nothing in this document exists in the repository.
>
> What replaced it: the app and `agentd` speak newline-delimited JSON over stdio, one line per
> message, which is what this ADR proposed to replace. That is the shipped wire format and it is
> documented in [docs/architecture/AGENTD-PROTOCOL.md](../../architecture/AGENTD-PROTOCOL.md).
> Durable state is not carried over a wire protocol at all: it is owned in process by
> `LibraryAuthorityRepository`, described in
> [docs/architecture/STORAGE-AND-PERSISTENCE.md](../../architecture/STORAGE-AND-PERSISTENCE.md).
> [The history index](../README.md) explains why the split was abandoned.

- Original status: Accepted
- Date: 2026-07-19
- Owners: Mechanician protocol, runtime service, app client, and agentd maintainers
- Related: [ADR-001](ADR-001-runtime-service.md),
  [architecture implementation plan](../ARCHITECTURE-IMPLEMENTATION-PLAN.md)
  (both also archived, both also superseded)

## Context

Mechanician's legacy direct app-to-agentd boundary is newline-delimited JSON with
hand-written dictionaries. It was useful while both sides had one lifecycle,
but it cannot safely become the boundary to a separately updated, persistent
Runtime Service. It has no negotiated compatibility range, durable command
identity, replay cursor, common generation rules, or end-to-end flow control.

The Runtime Service in ADR-001 may outlive every window and may still be running
when a newer app launches. Multiple clients need one ordered view of runtime
state. A dropped connection must not imply that a command was not accepted, and
a retry must not repeat an external effect. A delayed event from an old provider
process must not mutate a replacement process's state.

This ADR defines a generated, bounded, asynchronous protocol for app-to-service
communication and for service-owned adapters. It distinguishes reliable effects
from transport delivery: the transport may duplicate a frame, while durable
idempotency and idempotent reducers ensure that each effect is applied once.

## Decision

Protocol Buffers are the canonical runtime schema. Swift types are generated
with SwiftProtobuf and Node types are generated from the same `.proto` files.
The generated protocol is carried over authenticated XPC between app and
service. During the current provider-adapter migration, the service translates
validated typed commands and events to agentd's private, bounded NDJSON pipe;
that compatibility transport is not a second app command route.

Every runtime message is a `RuntimeEnvelope` with these required logical fields:

```proto
message RuntimeEnvelope {
  uint32 protocol_version = 1;
  string message_id = 2;       // lowercase canonical UUID text
  string correlation_id = 3;   // lowercase canonical UUID text, or empty
  string stream_id = 4;        // lowercase canonical UUID text
  uint64 sequence = 5;
  google.protobuf.Timestamp sent_at = 6;
  uint64 service_generation = 7;
  uint64 authority_epoch = 8;
  string service_instance_id = 9;

  oneof payload {
    ClientHello client_hello = 20;
    ServerHello server_hello = 21;
    RuntimeCommand command = 22;
    RuntimeEvent event = 23;
    Acknowledgement acknowledgement = 24;
    CancelRequest cancel_request = 25;
    CancelResult cancel_result = 26;
    ResumeRequest resume_request = 27;
    ResumeResult resume_result = 28;
    FlowControl flow_control = 29;
    RuntimeError error = 30;
    Heartbeat heartbeat = 31;
    ServiceLifecycleRequest service_lifecycle_request = 32;
    ServiceLifecycleStatus service_lifecycle_status = 33;
    TerminalOutputEvent terminal_output = 34;
    TerminalOutputAcknowledgement terminal_output_acknowledgement = 35;
  }
}
```

This excerpt mirrors the checked-in v1 envelope so field types and numbers are
reviewable here, but `protocol/runtime/v1/runtime.proto` remains the only
canonical schema. It supplies the exact nested messages, enum values, bounds,
and reserved field numbers.

`sent_at` is diagnostic metadata. Ordering and authorization never depend on
wall-clock time.

### Anthropic subscription policy is unchanged

Protocol extraction does **not** change Mechanician's Anthropic subscription
policy or authentication path. Subscription authentication remains supported
through the bundled Anthropic SDK/CLI integration. The schema carries a typed
authentication-mode identifier needed for routing and diagnostics, but never a
subscription credential, refresh token, session cookie, or policy decision.
No protocol version may make API-key billing a prerequisite for a previously
supported subscription flow.

## Canonical schema and generation

The repository contains:

```text
protocol/
  runtime/buf.yaml
  runtime/buf.gen.yaml
  runtime/v1/runtime.proto
  runtime/generated.sha256
app/Sources/MechanicianRuntimeProtocol/Generated/*.pb.swift
app/Sources/MechanicianRuntimeProtocol/Generated/RuntimeGeneratedSchema.swift
agentd/src/runtime-protocol/generated/v1/*
```

The SwiftProtobuf generator archive and digest are pinned by
`scripts/generate-runtime-protocol.sh`; the Buf and ES generators are exact npm
dependencies. Generated files and `generated.sha256` are committed so a release
build does not download code generators. Verification regenerates into a
temporary directory and fails on any diff.

CI fails when schema lint fails; regenerated Swift, Node, schema identity, or
golden hashes differ; or the bundled app/service resources do not match their
generated protocol and resource manifests. Review still treats field-number or
enum-value reuse and incompatible semantic changes under the same version as
breaking changes even though the v1 generator check is source-and-golden based.

Message and enum names describe domain semantics. They do not expose provider
JSON dictionaries. Provider-specific messages live below an explicit provider
adapter payload and remain generated.

Unknown protobuf fields are preserved when a peer relays a message. Unknown
enum values are handled as unsupported input, not coerced to a default action.
All enums reserve zero for `UNSPECIFIED`.

## Protocol version and feature negotiation

The wire represents a protocol version as one nonzero `uint32`. A peer advertises
the exact versions it can decode, and the service selects the highest common
value. An incompatible wire or semantic change receives a new value. Additive
capabilities within a selected version are enabled only through negotiated
`ProtocolFeature` values.

The XPC connection starts in `awaitingHello`. The only accepted first payload is
`ClientHello`, encoded with the stable bootstrap portion of the v1 schema. It
contains the client instance and application version, exact supported protocol
versions and features, requested limits and resume cursors, and a nonce.

The service selects the highest mutually supported protocol version and replies
with `ServerHello`, which contains:

- the selected version and features;
- service product/build versions and schema hash;
- authority epoch, service instance ID, service generation, and control-ledger
  schema;
- selected frame, blob, command-admission, replay, durable-event, and volatile
  terminal-output limits; and
- available stream cursors plus a server nonce.

If no version overlaps, `ServerHello.rejection` carries a typed
`PROTOCOL_VERSION_MISMATCH`, and the service closes the connection. If a
requested feature is not selected, commands that require it fail explicitly
before dispatch rather than silently degrading.

The service schema hash proves build provenance; compatibility is decided by the
selected version and negotiated features. A build whose advertised schema hash
does not match its signed resource manifest is rejected as damaged.

Before negotiation completes, every payload other than `ClientHello` is
rejected. Renegotiation requires a new XPC session.

## Authority and generation identity

Every post-handshake envelope includes:

- `authority_epoch`: the single-authority epoch from ADR-001;
- `service_instance_id`: a new random identity for each service process;
- `service_generation`: a monotonic generation persisted in the control ledger;
  and
- provider lane, process generation, provider session, thread, and turn
  identities on payloads where they apply.

A receiver validates every identity before invoking a reducer or external
effect. An older authority epoch is always stale. An older provider generation
cannot complete, cancel, or append output to a newer generation. A future epoch
or generation that the receiver has not negotiated is a protocol error and
forces reconciliation rather than speculative acceptance.

Provider generation retirement is one durable transition. The service fences
the generation, records a typed `ProviderStateEvent`, converts each newly lost
active turn/workflow/terminal into its ordinary recoverable terminal fact,
resolves cancellation records that were awaiting that generation, and revokes
generation-bound capability leases before a replacement can become ready. On
the app side, typed provider state is reduced with matching lane and generation;
an old-generation replay is durably consumed but cannot mutate replacement UI.
Durable terminal routes bound to the lost generation are terminalized once.

Mutating commands state the generation they observed when the operation is
generation-sensitive. Omitting that precondition is allowed only for commands
whose schema explicitly declares generation independence.

## Message identity and correlation

`message_id` is globally unique and immutable across retries of the same frame.
It identifies transport and audit handling, not the external effect.

`correlation_id` is the `message_id` of the request or causal root to which a
reply/event belongs. Streaming events retain a stable command/turn identity in
their payload; correlation alone is not used as domain identity.

`stream_id` names a durable ordered stream, such as a conversation, workflow,
terminal, or runtime-control stream. Stream IDs are stable and never reused for
different domain objects.

`sequence` is assigned monotonically by the stream's authoritative sender. For
service event streams it is allocated transactionally with the event. For
client command streams it is scoped to the authenticated client session and is
used to detect replay, reordering, and gaps; it is not an idempotency key.

## Commands and exactly-once effects

Every mutating `RuntimeCommand` contains a nonempty idempotency key. The service
computes a request fingerprint from the selected protocol version, payload type,
and deterministic protobuf serialization of the semantic command. Protobuf map
fields are not permitted in mutating command schemas unless canonical key
ordering is specified by the schema helper.

In one durable transaction the service:

1. validates authentication, version, bounds, authority, generations,
   capability, and preconditions;
2. inserts the idempotency key, fingerprint, command, and `accepted` state; and
3. inserts any required outbox item before acknowledging acceptance.

The unique idempotency constraint has these results:

- new key: durably accept and return `ACCEPTED`;
- existing key with the same fingerprint: return a `DUPLICATE` command result
  with the recorded outcome without repeating the effect; and
- existing key with another fingerprint: return a rejected result with
  `DUPLICATE_CONTENT_MISMATCH` and execute neither command.

A receipt of `ACCEPTED` means the command survives service restart. It does not
mean provider completion. A mutating command is never acknowledged as accepted
before its ledger transaction commits.

Network delivery remains at-least-once. Exactly-once **effects** are achieved by
durable idempotency at command dispatch, stable provider operation identities
where the provider supports them, and idempotent local reducers. When an
external provider cannot prove whether an operation crossed its boundary, the
command becomes `reconciling` or `recoverableOrphan`; it is not blindly retried.

Read-only queries normally need no idempotency key, but their response states the
snapshot or event high-water mark from which it was derived.

## Event streams, subscription, and replay

Runtime lifecycle, transcript/model output, tool state, permission state,
workflow transitions, terminal lifecycle, and terminal outcomes are durable
events. The service stores each event and its sequence before publication. Raw
PTY bytes are the explicit exception: they use `TerminalOutputEvent`, never a
`RuntimeEvent`, and never enter the durable journal or app projection inbox.

A client subscribes with its last durably applied sequence for each stream. The
service transactionally captures a high-water mark, then sends:

1. events in `(cursor, high_water]` in sequence order;
2. a replay barrier naming `high_water`; and
3. live events with sequences greater than `high_water`.

Live publication cannot overtake the replay barrier. Concurrent subscribers see
the same sequences; presentation-specific events use separate client streams.

Clients durably record a cumulative cursor only after applying the event to an
idempotent projection. Application caches are disposable: if a crash occurs
after apply but before cursor persistence, the repeated event has the same event
ID and sequence and changes no state. This is the exact-once replay contract.

Phase 1 retains durable events and does not age-prune or compact them. The v1
schema reserves `SNAPSHOT_REQUIRED`, oldest-sequence metadata, and
`StateSnapshotEvent` so Program 2 can add verified snapshot installation before
any retention boundary is enabled. Phase 1 therefore never silently skips a
gap, but it also does not claim cursor-expiry recovery or content-addressed
snapshot/compaction yet.

Terminal presentation data has a separate bounded reconnect contract. The
service keeps an in-memory suffix for each `(terminal_id, provider_access_lane,
provider_generation)` and sends absolute byte offsets. First attachment and
reconnect begin with a snapshot frame whose `dropped_before_offset` identifies
the oldest retained byte. Ordinary frames append contiguously. A client resets
presentation state for the snapshot and returns credit only after the owning
terminal presentation consumes the exact delivered frame; the acknowledgement's
exclusive end offset and returned byte count must match that frame. If no owner
is attached, bytes remain bounded and unacknowledged rather than being applied
to an arbitrary window.

Terminal process identity is not volatile. Before submitting `term_start`, the
app commits a route containing the service command ID, lane, presentation scope,
conversation, title, and working directory. Start records the provider
generation; exit leaves a durable tombstone. On relaunch, deterministic route
ownership restores input, resize, title, and kill actions to the existing
service-owned process before terminal output is acknowledged.

Ephemeral telemetry and presence do not share durable stream IDs. They travel on
explicit ephemeral streams and may be coalesced or dropped under pressure;
their loss cannot affect transcript, lifecycle, permissions, or user state.

## Framing and bounds

The XPC transport uses a small typed `XPCDictionary` frame containing protocol
magic, encoded-envelope `Data`, declared length, and optional XPC file-descriptor
attachments. Peer authentication is established by the XPC session, not by a
field inside the protobuf.

The current service-to-agentd compatibility transport uses one bounded JSON
object per newline. Its incremental framer rejects invalid, non-object,
oversized, and incomplete-at-EOF records before adapter translation. A future
generated service-to-agentd transport may use a four-byte unsigned big-endian
length followed by one protobuf envelope, but Phase 1 does not claim that
migration is complete.

Current defaults are negotiated downward:

- encoded envelope frame: 36 MiB, a transitional ceiling required to contain
  the bounded 32 MiB legacy adapter payload plus protobuf/XPC overhead;
- inline blob or bounded string field: 64 KiB unless a schema declares less;
- command admission: 64 in flight per client;
- durable delivery: 512 events and 64 MiB of serialized event payload credit;
- volatile terminal delivery: 256 KiB of independent byte credit;
- replay request: at most 10,000 events per stream;
- identifier collections: 1,024 entries; and
- command acknowledgement timeout: 15 seconds, with a 10-second heartbeat.

The generated validators enforce required logical fields, UTF-8 and scalar
bounds, identifier length, collection count, payload-specific limits, and
oneof presence after protobuf decoding. Unknown or invalid payloads do not reach
domain handlers. Oversized frames are rejected and the offending connection or
adapter is closed after a bounded error response; the service never attempts to
buffer an advertised oversized frame.

## Backpressure

Every subscription has negotiated message and byte credits. A cumulative
`Acknowledgement` advances the durable client cursor and returns per-stream
`StreamCredit`. The service sends only while both credits are available.

Volatile terminal output uses a separate negotiated byte-credit window. Its
exact-frame acknowledgement cannot replenish a durable subscription, and
durable event credit cannot replenish terminal output.

Each connection has a hard outbound queue limit. When a client is slow:

1. the service stops adding live frames to its memory queue;
2. durable events remain in the ledger;
3. coalescible ephemeral telemetry is replaced by its newest value;
4. the service issues a bounded `BACKPRESSURE` error if credit permits; and
5. it detaches the client, which later resumes from its cursor.

Lifecycle, terminal outcome, permission, command receipt, and user-output events
are never dropped to make room. Raw terminal bytes may roll out of their bounded
in-memory suffix, but this cannot cancel the terminal or discard its durable
lifecycle and outcome. Disconnecting a slow UI does not cancel its work.

Backpressure continues through the service-to-agentd adapter. The service
pauses pipe reads when its bounded decoder/ledger pipeline is saturated, and
agentd pauses provider stream consumption where the provider SDK permits it.
Commands have separate bounded admission queues per provider lane. A full queue
returns `BACKPRESSURE` before durable acceptance unless the command has
already been durably accepted, in which case it remains queued in the outbox.

Small control messages use a reserved credit budget so cancellation, receipts,
acks, and health probes cannot be starved behind output. Reserved credit is
strictly bounded and cannot carry arbitrary data.

## Cancellation

Cancellation is a typed durable request, not a local timeout side effect.
`CancelRequest` contains its stable cancellation ID, target message/command/
stream identities, expected service and provider generations, and a bounded
reason code. The service fingerprints the semantic request and records it
idempotently before dispatch.

`CancelResult` keeps two dimensions separate:

- `CancellationStatus` is the request disposition: `ACCEPTED`,
  `ALREADY_TERMINAL`, `NOT_FOUND`, or `REJECTED`; and
- `CancellationLifecycle` is the durable progress state: `ACCEPTED`,
  `RECONCILING`, or `TERMINAL`.

Generation or authority failures are represented by a rejected disposition plus
the typed `RuntimeError`/stable code; they are not extra enum cases. In
particular, an accepted disposition is not a claim that cancellation has
completed. It remains accepted or reconciling until an authoritative target
fact makes its cancellation lifecycle terminal.

Repeating the same cancellation ID and semantic content returns the recorded
result; reusing it for other content is rejected. A transport timeout never
proves that cancellation failed or succeeded. On reconnect the client includes
`unresolved_cancellation_ids` in `ResumeRequest`, and `ResumeResult` returns the
authoritative cancellation records alongside command and stream reconciliation.

Silence is not cancellation. In particular, a quiet Codex Ultra turn triggers
the authoritative reconciliation state machine from Program 0 and is never
killed solely because no output arrived.

## Reserved blob and file-descriptor transfer

The v1 schema defines `Blob`/`BlobReference` and feature identifiers for future
out-of-band transfer, but Phase 1 does not negotiate the file-descriptor or
content-addressable-blob features. The following is the required security
contract before either feature may be enabled; it is not a Phase 1
implementation claim.

Large prompts, files, artifacts, snapshots, images, and outputs are not embedded
in envelopes. They use a `BlobReference` containing:

- transfer ID and enumerated transfer mode;
- exactly one attachment name or content address;
- content digest and exact byte length; and
- media type.

For local upload, the sender offers a read-only XPC file descriptor. The receiver
copies from the descriptor into a private temporary file while enforcing the
declared and global byte limit, computes the digest during the copy, fsyncs, and
atomically installs it in service-owned content-addressed storage. It never
trusts a path supplied by the peer, follows peer-controlled symlinks, or reads
beyond the offered descriptor.

For download, the service opens a read-only descriptor for an immutable blob and
the client verifies length and digest before use. Transfer IDs and attachment
names are single-use and bound to the authenticated session, authority epoch,
and command by service state; peer-supplied filesystem paths never appear in the
wire schema.

Content-addressed blobs are reference-counted from durable state. Failed or
abandoned transfers are quarantined and garbage-collected after a grace period;
they are never treated as completed user content.

## Errors and degraded behavior

Protocol errors are typed and stable. Each contains a machine code, safe
message, correlation ID, retry classification, and optional expected/observed
version or generation. It contains no prompt, credential, environment, or
unbounded provider payload.

The checked-in v1 error classes are:

```text
PROTOCOL_VERSION_MISMATCH
UNAUTHENTICATED
UNAUTHORIZED
FRAME_TOO_LARGE
INVALID_ENVELOPE
INVALID_COMMAND
STALE_SERVICE_GENERATION
STALE_PROVIDER_GENERATION
DUPLICATE_CONTENT_MISMATCH
BACKPRESSURE
REPLAY_GAP
NOT_FOUND
CANCELLED
DEADLINE_EXCEEDED
PROVIDER_UNAVAILABLE
INTERNAL
```

Authentication failure is normally connection-level and occurs before an error
can safely be returned. Storage failure prevents mutation receipts. Sequence
gaps trigger replay, not best-effort continuation. Provider ambiguity triggers
reconciliation, not automatic duplicate dispatch.

## Security and privacy

The XPC signing and audit-token rules in ADR-001 authenticate app and service.
Protocol fields do not override peer identity.

The service-to-agentd pipe is created by the service, inherited only by its
signed/bundled child process, and never exposed as a named user endpoint. The
service applies a launch code requirement to bundled executable children where
the platform supports it and verifies bundled resource hashes at startup.

Envelope and ledger diagnostics include IDs, versions, sizes, state transitions,
and error codes. Prompts, model output, tool payloads, blob content,
environment variables, access tokens, cookies, and credentials are excluded by
default. Redacted export follows the bounded diagnostics rules already used by
the Codex lifecycle trace.

Capability and permission decisions are typed messages tied to a command,
generation, and single-use nonce. Free-form provider text cannot be decoded as a
permission decision or capability grant.

## Migration and compatibility

Migration follows these gates:

1. Land schemas, generated types, validators, fixtures, and an in-process
   `RuntimeTransport` interface while the direct runtime remains authoritative.
2. Put existing NDJSON agentd traffic behind a compatibility adapter. Compare
   generated command/event round trips against captured redacted fixtures.
3. Register the service in shadow mode. Exercise handshake, authentication,
   bounds, replay, backpressure, and blob transfer without provider effects.
4. At an idle authority cutover, route one profile to the service. Thereafter
   all UI traffic uses protobuf/XPC; no window may open a direct pipe.
5. Convert service-to-agentd message families to generated protobuf in bounded
   vertical slices. The compatibility adapter remains private to the service
   and cannot become a second command route.
6. Make service mode default, retain one prior major/minor compatibility range
   through the rollback window, then delete NDJSON and direct-runtime code.

Rollback is allowed only under ADR-001's idle, checkpointed authority transition.
The prior app/service decoder remains able to read all ledger envelopes created
during its advertised compatibility window. If a new required semantic cannot
be represented, the release raises the protocol major version and rollback is
blocked after use of that feature rather than losing data.

Every migration build records the selected transport, authority epoch, protocol
version, feature set, schema hashes, and compatibility-adapter use in redacted
diagnostics.

## Testing strategy

Generated golden fixtures are decoded and re-encoded by Swift and Node. Property
tests cover identifiers, bounds, Unicode, unknown fields, enum values, and every
oneof. Fuzzers feed both framed bytes and decoded protobufs and assert bounded
memory and deterministic rejection.

A deterministic transport harness introduces:

- partial, combined, malformed, truncated, and oversized frames;
- duplicate, missing, reordered, and delayed messages;
- disconnect before and after durable command commit;
- duplicate idempotency keys with equal and unequal fingerprints;
- stale authority, service, provider, thread, and turn generations;
- replay during concurrent live publication;
- zero-credit and persistently slow clients;
- terminal snapshot/append offsets, exact byte-credit acknowledgement, owner
  detach/reattach, and bounded suffix rollover;
- cancellation racing acceptance, provider reconciliation, reconnect, and
  terminal completion;
- provider generation retirement racing replacement readiness;
- service and agentd death at every commit/outbox boundary.

Cursor-expiry and content-addressed snapshot recovery tests become mandatory
before Program 2 enables any retention or compaction boundary; they are not a
Phase 1 completion claim.

Incorrect blob length, digest, attachment identity, authority, generation, and
expiry become mandatory tests before the corresponding blob features are
advertised or required.

Signed integration tests connect two app clients to one LaunchAgent, reject
wrongly signed peers, upgrade app and service independently within the supported
range, and prove explicit incompatibility outside it. A long soak asserts
bounded transport and volatile-terminal queues, observable durable-ledger
growth, contiguous stream sequences, one terminal outcome per accepted command,
and no duplicate external dispatch.

## Rejected alternatives

### Continue with NDJSON dictionaries

Rejected because hand-written, unbounded, newline-framed dictionaries cannot
provide generated cross-language compatibility or safe evolution.

### Put Codable JSON inside XPC and call it versioned

Rejected because adding a version field would not supply schema generation,
reserved field evolution, descriptor checks, or shared Swift/Node validation.

### Promise exactly-once network delivery

Rejected because disconnects make that promise impossible. Durable command
deduplication and idempotent replay provide the product property that matters:
exactly-once effects.

### Include all data inline

Rejected because large model/tool/artifact payloads would defeat bounded framing
and backpressure and create avoidable memory amplification.

### Retry on timeout

Rejected because timeout does not reveal whether the service or provider
accepted the operation. Retry uses the same idempotency key and first reconciles
recorded ownership.

### Require exact schema hashes

Rejected because it would turn safe additive changes into needless
incompatibilities. Version, declared features, and breaking-change validation
define compatibility; hashes prove build provenance.

## Consequences

Positive consequences:

- app and service can update independently within an explicit range;
- retries and reconnects do not duplicate side effects;
- every client can reconstruct ordered runtime state;
- stale process output cannot mutate current state;
- memory use is bounded across frames, replay delivery, volatile terminal
  output, blobs, and slow clients; and
- Swift and Node share one reviewed protocol instead of parallel dictionaries.

Costs:

- schema and generator changes become part of the release process;
- commands and reducers must be written for idempotency and replay;
- the Phase 1 control ledger must retain durable events until Program 2 supplies
  a verified projection/snapshot boundary;
- provider adapters need explicit flow-control and ambiguity handling; and
- compatibility must be tested across at least the supported app/service matrix.

## Acceptance criteria

The Phase 1 portion of this ADR is implemented only when tests prove:

- generated Swift and Node code come from one reviewed schema and golden digest
  manifest with no verification drift;
- compatible peers negotiate one version and incompatible peers fail before any
  runtime command;
- invalid, unauthenticated, oversized, unsupported, sequence-gap, and stale-
  generation inputs are rejected deterministically;
- mutating-command acknowledgement occurs after durable acceptance;
- retrying any accepted command produces one external effect and the recorded
  outcome;
- two windows observe identical contiguous event sequences;
- reconnect and app relaunch replay missed durable events with idempotent UI
  effects and no duplicated transcript output;
- slow clients and providers cannot grow unbounded queues or starve control
  messages;
- volatile terminal output never enters the durable journal, remains bounded,
  resumes from an offset-bearing snapshot, and returns only exact consumed-byte
  credit;
- terminal routing survives app/window loss and controls the existing process
  after relaunch;
- accepted cancellation remains nonterminal until reconciliation or target
  outcome makes its lifecycle terminal, including across reconnect;
- provider generation failure/replacement atomically produces one recovery fact
  per newly orphaned activity and stale output cannot mutate replacement UI;
- service/agentd failure at each transaction boundary recovers without blind
  provider redispatch; and
- Anthropic subscription authentication continues through the unchanged
  supported path without credentials entering protocol messages.

Before Program 2 may delete retained history, tests must additionally prove that
a cursor outside retention installs and validates a content-addressed snapshot,
persists its base sequence, and resumes without skipping or duplicating events.

## References

- [Protocol Buffers language guide](https://protobuf.dev/programming-guides/proto3/)
- [SwiftProtobuf](https://github.com/apple/swift-protobuf)
- [Buf breaking-change detection](https://buf.build/docs/breaking/)
- [Apple: XPC](https://developer.apple.com/documentation/xpc)
