# Codex lifecycle diagnostics and reliability tests

Mechanician treats a Codex App Server turn as a provider-owned lifecycle rather than inferring
completion from elapsed time. A quiet turn is reconciled with `thread/read(includeTurns: true)`;
it is never interrupted merely for being quiet.

## Export a redacted trace

Open **Mechanician → Settings → Advanced**, then choose **Export Redacted Lifecycle
Diagnostics…**. The button is available while the Codex subscription runtime is connected.

The JSON export is reconstructed from allowlisted fields in both agentd and the Swift app. It
contains the bundled Codex version and schema hash, process generation, hashed conversation
identity, model and effort, provider thread/turn identity, lifecycle transitions, reconciliation
status, timestamps, and bounded error/restart classifications.

It never contains prompts, assistant output, tool arguments or results, environment values, or
credentials. The in-memory trace and export are capped at 256 entries.

## Deterministic fault matrix

The fake App Server integration suite covers:

- dropped, duplicated, reordered, oversized, and pre-acknowledgement notifications;
- a terminal response recovered from authoritative thread history;
- legitimately quiet Ultra work and approval/user-input wait states;
- idle-thread or active-thread ownership disagreement;
- lost reconciliation responses and bounded provider restart;
- "no active turn" during interrupt;
- process exit between `turn/start` response and the first notification;
- stale events, process-generation replacement, steering, approvals, subagents, concurrent turns,
  control-pipe/window closure, and resumed threads; and
- exact-once transcript output, tool completion, and local terminal events.

Run the normal matrix with:

```bash
cd agentd
npm test
```

Run the seeded high-volume state-machine soak independently with:

```bash
cd agentd
npm run soak:codex -- --iterations 100000
```

`MECHANICIAN_CODEX_SOAK_ITERATIONS` and `MECHANICIAN_CODEX_SOAK_SEED` provide repeatable CI or
release-candidate overrides. The command exits nonzero on any indefinite accepted turn, duplicate
terminal transition, stale-generation acceptance, or silence-only termination.

## Release-candidate dogfood

The deterministic gate does not replace validation against the external provider. Before a release
that changes this adapter:

1. Run fresh and resumed Codex conversations at both a lower effort and Ultra.
2. Include a long quiet reasoning turn, a tool-heavy turn, an approval wait, steering, and an
   interrupt.
3. Confirm the UI surfaces approval/input waits and every accepted turn leaves its running state.
4. Export diagnostics immediately after the run and verify that the expected lifecycle categories
   are present and no private content appears.

This live step intentionally remains human-controlled because it consumes the user's subscription
and depends on provider behavior outside the deterministic test boundary.
