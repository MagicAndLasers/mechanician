# Archived documents

Nothing in this directory describes how Mechanician works today, and nothing in it should be
implemented. These files are kept because they explain why the current architecture has the shape
it has, and because deleting them would invite the same arguments a second time.

If you are looking for how the app actually works, start at
[docs/architecture/OVERVIEW.md](../architecture/OVERVIEW.md). The protocol that shipped is
[docs/architecture/AGENTD-PROTOCOL.md](../architecture/AGENTD-PROTOCOL.md). The storage design is
[docs/architecture/STORAGE-AND-PERSISTENCE.md](../architecture/STORAGE-AND-PERSISTENCE.md).

## The Runtime Service

Five of the six documents here belong to one episode.

In July 2026 the app created provider runtimes from window state, so closing a window could kill
work and two windows could start competing provider processes. The response was a per-user Runtime
Service: a signed `LaunchAgent` that would own every provider process, every terminal, and the
durable record of accepted work, with the app demoted to one of several possible clients talking to
it over authenticated XPC using a generated Protocol Buffers schema.

It was designed, built, and shipped as 0.10.0 on 2026-07-19. It was reverted on 2026-07-20.

```
git show --shortstat ea885ed
#  143 files changed, 691 insertions(+), 44338 deletions(-)

git log --format='%s' | grep -oE '^chore\(release\): 0\.10\.[0-9]+' | sort -u | wc -l
#  15
```

Fifteen releases went out in the roughly twenty-six hours the service was alive, almost all of them
stabilising it. The revert commit is `ea885ed`, "restore: ship the lean stable baseline".

### What replaced it

Nothing. The arrangement the service was built to replace is the arrangement that ships:

- The app spawns `agentd` as a child process and owns it. Each workspace window runs its own
  `agentd` per provider lane, and closing a window kills that window's `agentd`. This is why
  `AgentBridge` carries a `bridgeID`: keying anything on the provider lane alone would let two
  windows overwrite each other's state.
- App and daemon exchange newline-delimited JSON on stdio, one JSON object per line. There is no
  schema compiler, no negotiated version range, and no upgrade handshake, because the two always
  ship in the same bundle.
- Durable state is owned in the app's own process by `LibraryAuthorityRepository`, not by a
  service. Helpers that need to hand work to it write immutable inbox files rather than opening the
  database.
- The one guarantee the service was actually built for, keeping two conversations from writing over
  each other in the same repository, was a filesystem lease in `agentd/src/write-lease.mjs`: a few
  hundred lines, not a service.

That last point is the one worth understanding, because it is the argument that ended the project.
The service split its workers by provider lane, so a Claude conversation and a Codex conversation
were in different processes inside it, and `ambientd` was outside it entirely. The architecture
built to make concurrency safe could not see the collision it was supposed to prevent. The
filesystem is the only place all three meet.

The lease itself is gone now, and its ending is the same lesson told twice. It shipped observe-only,
with a stated exit condition: nobody had ever counted how often two writers actually want the same
directory. Three weeks of logs recorded two contention events, both unreadable because the log line
stringified an object. The answer was ~zero, so the instrument was deleted in favour of the thing it
had proved unnecessary. Measure first, then delete, including the measurement.

### The lessons

These are the reason this directory exists.

**State the user-visible outcome before you start, or do not start.** "A foundation for X" is not an
outcome. The service delivered two things nobody had asked for (work surviving a window close,
multiple windows sharing one provider session) and never delivered the concurrent-write safety that
justified it. Every other failure below compounded on top of that one.

**A figure in a plan is a hypothesis until someone opens the file.** Two numbers drove this work and
neither survived contact with the source. "Delete about 1,900 lines of legacy handoff" turned out to
name the live worker. "Nearly half the code is upgrade machinery" turned out to be about a hundred
lines, entangled with everything else. Both were checkable in minutes. Both were checked after the
decision instead of before it. All three premises about what the service would fix were the same:
`ambientd` predated it and referenced it nowhere, `agentd` was already isolating concurrent turns,
and `codex-lifecycle.mjs` was byte-identical before and after.

**Identity is not liveness is not authority.** A durable record naming a thing is not evidence that
the thing is running, and neither is evidence that it can be addressed now. While the app and its
runtime shared one process lifetime these were the same fact, so the codebase was full of call
sites that assumed it. Splitting one lifetime into three made all of them wrong at once, with no
compiler error and no failing test: transport liveness read as "account authenticated", a tool-call
exit code read as "agent needs attention", a retained route read as "tab permanently dead". Patching
call sites did not converge. Fixing one instance produced the opposite bug on the same line, because
a dictionary of lane identifiers cannot express "routed but not running".

The fix that worked was changing the type until it could state the difference. `AgentBridge`'s
`turnRoutes` is now keyed to a `TurnRoute` struct carrying a `TurnRoutePhase` of
`.starting` / `.active` / `.completed(Date)`, and the callers ask `isActive` or
`reservesConversation` rather than testing for the key's presence. When a fix looks like "add a
condition at this call site", check whether the type can be made to hold the distinction instead.
Read it with:

```
grep -n 'enum TurnRoutePhase' -A 25 app/Sources/Mechanician/AgentBridge.swift
```

**Verification cost is a design input.** Three releases were spent verifying ten-line changes,
because the service could only be exercised as an installed, signed build. Run `./dev.sh`: it
builds and assembles a runnable bundle from the working tree, and costs no version number and no
notarization round trip. Releases are for delivering. They are not a debugging tool.

**Deleting is progress.** The revert removed tens of thousands of lines and the product got better.
A change that only adds structure, with no outcome attached to it, is not neutral.

### The files

- [adr/ADR-001-runtime-service.md](adr/ADR-001-runtime-service.md) proposed the service: process
  ownership, the `SMAppService` LaunchAgent, XPC peer requirements, and the minimum durable state it
  would hold.
- [adr/ADR-002-runtime-protocol.md](adr/ADR-002-runtime-protocol.md) specified the wire protocol
  between app and service: Protocol Buffers as the canonical schema, generated Swift and Node types,
  durable command identity, replay cursors, and flow control. None of the generated code survives.
- [adr/ADR-003-runtime-availability-and-upgrades.md](adr/ADR-003-runtime-availability-and-upgrades.md)
  covered admission and version skew between an app and a service that could be updated separately.
  Its one durable idea is that transport, authentication, catalog, and command admission are four
  separate authorities and collapsing them into one readiness bit is what makes a reconnect look
  like a logout.
- [ARCHITECTURE-IMPLEMENTATION-PLAN.md](ARCHITECTURE-IMPLEMENTATION-PLAN.md) was the program that
  ordered the work. Programs 1 through 3 are the service and are void. Program 0, Codex lifecycle
  reconciliation, is the part that shipped and survived. Program 2 wanted a service to own durable
  state; an authoritative SQLite database did ship, but in the app's process. Program 3's automatic
  managed worktrees were dismissed separately, on their own merits.
- [PHASE-1-RUNTIME-SERVICE-VERIFICATION.md](PHASE-1-RUNTIME-SERVICE-VERIFICATION.md) was the
  acceptance checklist the service never cleared. It is useful now only as a list of properties a
  process boundary has to guarantee, several of which were later met by other means.

## Postmortems

- [POSTMORTEM-schema-v7-active-authority-brick-2026-08-14.md](POSTMORTEM-schema-v7-active-authority-brick-2026-08-14.md)
  records the day a schema bump (`library.db` v6 to v7, commit `6efaa1d`) shipped green and bricked
  launch for every existing library. The migration ran only on disposable shadow databases, the
  active-authority open path demanded an exact schema match with no upgrade path, and the test suite
  only ever provisioned fresh. Read it before you change `SQLiteLibraryStore.schemaVersion` again.

## Unrelated to the revert

- [INITIAL-RESPONSE-PERFORMANCE-AND-AGENT-CARDS-PLAN.md](INITIAL-RESPONSE-PERFORMANCE-AND-AGENT-CARDS-PLAN.md)
  is a July 2026 plan for first-response latency, automatic context maintenance, and richer agent
  cards. It was abandoned part-built and the document does not mark which parts landed, so it cannot
  be read as a description of behaviour. Its useful residue is the distinction it insists on between
  native provider compaction, retiring a session and replaying history into a new one, and bounded
  history replay with no source session. Those are different outcomes with different costs, and the
  shipped code still names them separately.
