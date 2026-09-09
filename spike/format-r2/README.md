# Format spike: THROWAWAY prototypes, not shipping code

Nothing in this directory ships. No file here is a public schema, a file format the app can read or
write, or a commitment to any of the encodings it prototypes. Nothing in `app/` or `agentd/` imports
it, and the packaging scripts never copy it (`grep -rn "spike/" agentd/src app/Sources scripts`
returns only `scripts/check.sh`). Treat every module here as an experiment whose only product is a
measurement.

## What it measures

An agent turn produces a stream of events (agents, parentage, tool calls, steering, usage, provider
errors, lifecycle) that the app persists. The question this prototype exists to answer is what a
durable record of that stream should look like. It compares three candidate semantic roots:

- **A, `encode-vcon.mjs`**: a vCon-shaped record with an embedded provisional trace. It omits
  required Agent Session party metadata and does not cross-check dialog against the embedded trace,
  so it is explicitly not a conformance implementation.
- **B, `encode-acr.mjs`**: a record in the verifiable-agent-record shape. Its original field
  vocabulary does not pass the pinned CDDL; self-decoding shows internal mapping only, not
  conformance.
- **C, `canonical.mjs`**: a multi-agent event graph in which agents, parentage, agent-to-agent
  edges, producer metadata, turn lifecycle, usage, provider errors, steering requests and responses,
  and child lifecycle are first-class, and provider control handles are replaced by record-local
  identities.

Each root is encoded and decoded again, and the result is compared against the input. The output is
a loss and deviation report per root plus a byte count, not a verdict.

Separately, `bindings/` compares how a record is physically written: one whole-file rewrite per
commit (`binding-monolith.mjs`, the control, modelled on the JSON sidecar write), an append-only
framed log (`binding-framed.mjs`), and a directory of content-addressed chunks behind an atomically
replaced head (`binding-chunked.mjs`). `framed-kill-writer.mjs` exists to be killed mid-write so
recovery can be tested against a torn frame. These are measurements of write and read cost, not a
proposal for how the app stores anything; see
[docs/architecture/STORAGE-AND-PERSISTENCE.md](../../docs/architecture/STORAGE-AND-PERSISTENCE.md)
for what the app actually does.

## Running it

```bash
cd spike/format-r2
node run.mjs                        # one fixture through all three roots; prints JSON
node --test test/*.test.mjs         # the full spike suite
```

`run.mjs` defaults to `agentd/test/fixtures/nested-delegation-fixture.mjs`; pass a different fixture
path as the first argument. `capture.mjs` runs a fixture generator as a child process and records
its NDJSON output, stamping arrival order and an observation time. Fixtures emit no provider
timestamps, so those times are marked capture-approximate downstream and are never presented as
provider event times.

`measure.mjs` and `bindings/bench-bindings.mjs` need real Conversation JSON, which is not in this
repository. Point `MECHANICIAN_FORMAT_CORPUS` at a directory of Conversation sidecars to run them.
Without it they exit with a message and do nothing.

The standalone `*-evidence.mjs` generators compare their deterministic results with reviewed
artifacts held outside this repository. Set `MECHANICIAN_FORMAT_EVIDENCE_REPOSITORY` to the
absolute path of that evidence checkout before running one. The checkout must contain
`docs/mechanician/agent-document-format`. The unit tests and CI never require this variable; they
use only the deterministic fixtures checked in here. The paired-volume harness likewise accepts
its checked-in fixture without external state and consults the configured checkout only when a
reviewed corpus fixture is requested.

## This is a hard gate on every pull request

`scripts/check.sh` runs `node --test "$REPO"/spike/format-r2/test/*.test.mjs`, and CI runs
`./scripts/check.sh`. A failure here is a red build, so the spike cannot rot quietly behind an
otherwise-green repository.

The trap worth knowing before you edit the daemon: `REVIEWED_CAPTURE_SOURCE_PINS` in
`canonical-field-contract.mjs` pins the SHA-256 of 16 files, seven of them production sources
(`agentd/src/agentd.mjs`, `agentd/src/claude-compaction-summary.mjs`,
`agentd/src/claude-message-events.mjs`, `agentd/src/codex-workflows.mjs`,
`agentd/src/tool-surface.mjs`, `agentd/src/harness-observations.mjs`,
`agentd/src/otel-metrics-receiver.mjs`) and nine of them every fixture in
`agentd/test/fixtures/`.
`test/field-fidelity.test.mjs` rehashes
each one and asserts the pin. **Editing any of them fails the spike suite until someone re-audits
the field inventory and updates the pin.** That is deliberate: those seven sources define the
reviewed or explicitly bounded event surface, and a silent producer change would make the audit
stale. It is not a mistake in the test.

`canonical-from-sidecar.mjs` is a forwarding module, not a copy: it re-exports from
`agentd/src/convrec/canonical-from-sidecar.mjs` so the harness runs against the implementation
actually in the product.

## `specs/`

`specs/` holds encoding specs written against pinned IETF draft text, with line citations and trap
notes, so the encoders are written against a spec rather than from memory:

- `vcon-core.md`: minimal valid unsigned vCon (`draft-ietf-vcon-vcon-core-03`).
- `agent-session.md`: the Agent Session binding onto a vCon
  (`draft-howe-vcon-agent-session-00`), including where it disagrees with core -03.
- `acr-vac.md`: minimal valid JSON verifiable-agent-record
  (`draft-birkholz-verifiable-agent-conversations-00`).

These three Markdown files are in this repository. The pinned draft `.txt` files they cite are not,
so the line numbers in the citations cannot be checked from a clone alone. The drafts themselves are
public at datatracker.ietf.org.

The worked JSON examples in these specs use a fictional party (Alex Rivera, alex@example.com). They
are illustrations of the encoding, not captured data.
