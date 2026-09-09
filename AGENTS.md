# Mechanician repository conventions

Conventions for anyone changing this repository, human or agent. Read
[CONTRIBUTING.md](CONTRIBUTING.md) first for setup, then
[docs/architecture/OVERVIEW.md](docs/architecture/OVERVIEW.md) for how the app and the daemon fit
together and which file owns what.

## Verification

Run `./scripts/check.sh` before you call an app change complete. It is the same command CI runs, so
a green local run and a green pull request mean the same thing. It checks shell syntax, the
Info.plist, a locked `npm ci` plus the agentd test suite and a production audit, `node --check` over
every `agentd/src` and `agentd/test` module, the format-spike tests, the bundled Codex version pins,
the staged production SBOM, `swift test --arch arm64`, the Swift warning budget, the localization
ratchet, and `git diff --check`.

Two of those surprise people. The localization ratchet (`scripts/localization-baseline.sh`) counts
strings that are not yet translatable and refuses an increase, so a new user-facing literal can fail
the run. The format-spike tests pin hashes of some `agentd/src` files, so editing the daemon can
fail a test that looks unrelated; see [spike/format-r2/README.md](spike/format-r2/README.md).

For packaging changes also run `./scripts/dogfood.sh`, which builds and signs the production-shaped
app without notarizing or publishing. Its `--install` mode replaces and relaunches the installed
app, so run that one from a plain Terminal rather than from inside the app under test.

## Branches and commits

Ship from `main`. Do not leave completed work only on a topic, backup, restore, or archive branch.

Preserve user changes already in the worktree. Prefer focused commits with conventional subjects
(`feat(scope): …`, `fix(scope): …`, `chore(scope): …`).

## Storage

Full detail, including the on-disk layout and the recovery paths, is in
[docs/architecture/STORAGE-AND-PERSISTENCE.md](docs/architecture/STORAGE-AND-PERSISTENCE.md). The
parts you need before you touch persistence:

- `library.db` sits at the root of the app's support directory: `~/Library/Application
  Support/Mechanician`, or whatever `MECHANICIAN_SUPPORT_DIR` names. `dev.sh` points a dev build at
  `Mechanician-dev` instead, so a dev run never touches the installed app's data. `library.db` is
  the sole product authority for Conversations, Workspaces, artifacts, retained media references,
  and scheduled-task state. A genuinely pristine root is provisioned directly as an empty SQLite
  authority; an unmarked root with any legacy facts is recovery-only and must first be opened with
  Mechanician 0.26.21. Frozen sidecars and rollback generations may remain temporarily as reclaimable
  evidence, but normal product code never reads or writes them.
- The root decision lives in a marker file next to the database, not in the database
  (`StorageAuthorityProtocol` in `app/Sources/Mechanician/StorageAuthorityMarker.swift` names the
  marker, the database, and the single-writer lease). The marker is written last for pristine
  bootstrap. Existing product roots must present a matching active marker/database pair; uncertainty
  blocks launch rather than constructing retired writers. The launch decision is
  `StorageAuthorityLaunchDecision` in `app/Sources/Mechanician/MechanicianApp.swift`.
- `projections.db` (`app/Sources/Mechanician/ProjectionStore.swift`) is a disposable full-text
  search and summary projection. It may lag the authority, it may never lead it, and deleting it is
  never data loss. Do not put a fact there that nothing else owns.
- Adding a stored property to a persisted `Codable` type is a compatibility change even when the
  property has a default value, because the synthesized `Decodable` ignores defaults and one
  `keyNotFound` rejects the whole record. Persisted types therefore decode through a hand-written
  tolerant `init(from:)`; `Conversation`'s is in `app/Sources/Mechanician/AgentBridge.swift` (grep
  for `// Tolerant decode`), with a `Failable` wrapper behind it so an undecodable element costs one
  row instead of the conversation. Any repair the decoder performs on purpose must also be declared
  in `app/Sources/Mechanician/ConversationDecodeNormalization.swift` so recovery and compatibility
  readers apply the same normalization contract.

## Do not predict what an agent needs

Context that is guessed at rather than addressed does not reach the right turn. This was built here
at full scale and measured. The result was negative and the subsystem is being removed. Do not
rebuild it.

The system stored facts learned from conversations and tried to select the relevant ones at the
start of each turn. At its largest it was 83 Swift sources and 44,733 lines, with 129 test files and
1,337 test functions behind it, plus 24 tables, 24 indexes and 62 triggers in `library.db`. That is
roughly a fifth of the app's Swift and about a third of its tests.

The selection step is the part that failed, and it failed for a reason no amount of tuning reaches.
Deciding which stored facts a turn needs requires understanding the task. Understanding the task is
the agent's job. So the selector was running a weaker copy of the agent's own reasoning, one step
earlier, with less information and none of the tools. It also had nothing to rank with: on the live
library the cosine similarity between statement embeddings ran from 0.69 to 0.998 with a median of
0.90, which is close to no signal.

Two results from the same work are worth keeping, because they stop this from being read as
"knowledge systems do not work here".

**Capture worked.** Deciding what to write down, from a message already in front of you, went from
about 10% to about 94% precision on the real library once it was split into a judge, a span selector
and a fact writer. Writing things down was never the problem.

**Attachment beats asking.** Over a 600-statement library, 267 recalls arrived because the app
composed them onto the turn and 26 arrived because a model chose to call the tool. Both figures are
recorded in `agentd/src/agentd.mjs`; grep for `arrived by attachment`. Waiting for a model to reach
for a tool is not a delivery mechanism. That half of the finding still holds and should be reused.

So the rule for anything that puts context in front of an agent:

**Every piece of context must arrive because of an explicit edge or an observed event, never because
something scored it as probably relevant.** A claimed work item, a file another conversation just
edited, a declared link between two items, a message posted in the last hour by a conversation that
is still running: each of those is a join on a key the app already holds exactly. None of them is a
search.

The tell for a proposal that is repeating this mistake is that it needs a ranker, a threshold, a
similarity score, or a "surface the most relevant" step. If the design cannot say which exact key
connects the context to the turn, it does not have one, and the model will do that work better
itself.

## Feature requests

Open a GitHub issue, or describe the change in the pull request. Either is a complete record for a
change to this repository. Nothing else is required of you and nothing else is expected.

Maintainers additionally mirror user-facing requests into a separate product ledger; that mirroring
is not a contributor step and never blocks a pull request.
