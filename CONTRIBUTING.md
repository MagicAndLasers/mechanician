# Contributing to Mechanician

Read [docs/architecture/OVERVIEW.md](docs/architecture/OVERVIEW.md) first: it covers the process
topology (a native Swift app with an AppKit-owned shell and SwiftUI content views driving a
headless Node daemon over newline-delimited JSON) and points at the subsystem document for your
change.

## Before you start

Mechanician runs agents that execute shell commands, edit files, drive a PTY, control the Mac
through the Accessibility APIs, and can run scheduled work with nobody watching. Read
[SECURITY.md](SECURITY.md) before touching the tool, permission, or account paths, and report
vulnerabilities privately through the repository's Security tab, never as a public issue.

## Requirements

- **macOS 26 or later.** `app/Package.swift` declares `.macOS(.v26)`; CI runs on `macos-26`.
- **Apple Silicon.** Tests run `swift test --arch arm64`; the bundled Codex App Server is
  `@openai/codex-darwin-arm64`.
- **Node.js 24 or later.** `scripts/check.sh` exits below major 24.
- **Swift 6.2 toolchain.** `app/Package.swift` is `swift-tools-version:6.2` with
  `swiftLanguageModes: [.v5]`, so Swift 6 strict concurrency is not on.
- **Packaging only:** `build-app.sh` defaults `DEVELOPER_DIR` to `/Applications/Xcode.app` and
  hard-exits unless `xcodebuild -version` reports exactly **Xcode 26.6, build 17F113** and
  `xcrun --sdk macosx --show-sdk-version` reports **26.5**. All three are defaults, overridable
  with `MECHANICIAN_XCODE_VERSION`, `MECHANICIAN_XCODE_BUILD`, and `MECHANICIAN_SDK_VERSION` for a
  local experiment. `dev.sh` does not pin, and selects the newest installed SDK instead, so dev and
  release builds routinely compile against different SDKs.

`scripts/check.sh` needs network access (`npm ci`, `npm audit`, `npm audit signatures`).

## First build and first run

```bash
cd agentd && npm ci && cd ..
./dev.sh
```

`dev.sh` does **not** use `swift run`, whatever older docs say. It runs `swift build` with the
linker flags that embed the Info.plist into `__TEXT,__info_plist` (TCC reads the embedded plist,
not `Contents/Info.plist`), extracts App Intents metadata, assembles `build/Mechanician-dev.app`,
ad-hoc signs it, and execs the binary. A bare `swift build` compiles, but the result cannot run as
the app.

The dev bundle is a separate identity: `ai.mechanician.app.dev`, name "Mechanician Dev", URL scheme
`mechanician-dev`, store at `~/Library/Application Support/Mechanician-dev`. It cannot see an
installed app's conversations and never self-updates. It runs `agentd/src/agentd.mjs` from your
checkout, so a daemon edit needs an app restart, not a rebuild.

## Getting a turn to actually run

The dev build exports its own `MECHANICIAN_CONFIG_DIR`, so it does not inherit an existing
`~/.claude` login. Sign in inside the dev app: **Window ▸ Providers** (Cmd-Option-A), then connect
an account.

To exercise the UI with no credentials, use the mock lane:

```bash
MECHANICIAN_AUTH=apikey MECHANICIAN_ENABLE_MOCK_PROVIDER=1 ./dev.sh
```

`MECHANICIAN_ENABLE_MOCK_PROVIDER` is read once (`grep -n MECHANICIAN_ENABLE_MOCK_PROVIDER
agentd/src/agentd.mjs`) and reaches `runMock` only when no real lane is selected. Both halves
matter: on the subscription route the daemon reports `mode: "sdk"` and the turn fails credential
preflight, so you also need `MECHANICIAN_AUTH=apikey` and no `ANTHROPIC_API_KEY` in the
environment, the login keychain, or `agentd/.env` (those are the three places `dev.sh` looks, in
that order). `dev.sh` never sets `MECHANICIAN_ENABLE_MOCK_PROVIDER` itself. Without the variable,
`mode` stays `"unavailable"` and every turn errors, which is what `dev.sh` says when it finds no
key: "agentd will start unavailable and every turn will fail."

## Where the logs are

The daemon's stderr is the real diagnostic channel: one file per provider lane at
`~/Library/Application Support/Mechanician{,-dev}/logs/agentd-<access>.log`, mode 0600, rotated to
`.previous.log` past 5 MiB (`openStderrLog` in `AgentdRuntime.swift`). Swift-side logging is
`NSLog`, so it lands in the unified log. Scheduled work logs to
`~/Library/Logs/ai.mechanician.ambient*.log`. There is no crash reporter or first-party telemetry
upload. Provider harnesses can emit bounded, content-free metrics to an app-owned loopback-only
receiver; nothing in that path is exported from the Mac.

## ./scripts/check.sh

One command, and exactly what CI runs (`.github/workflows/ci.yml`). Twelve gates: eleven print a
banner (`grep -n 'echo "==>' scripts/check.sh`; its twelfth hit is the closing "all checks
passed"), and `scripts/localization-baseline.sh` prints its own.

| Gate | Fails on | Fix |
| --- | --- | --- |
| shell syntax | `bash -n` on every `*.sh` in the working tree, tracked or not | fix the script |
| property lists | `plutil -lint app/Mechanician-Info.plist` | fix the plist |
| customer names | a tenant's name appears in a tracked file | below |
| locked agentd install | `npm ci` drift, the agentd test suite, or `npm audit --omit=dev --audit-level=high` | commit `package-lock.json`; fix the test; upgrade the dependency |
| Node source syntax | `node --check` on any `.mjs` in `agentd/src` or `agentd/test` | fix the syntax |
| format spike tests | `node --test spike/format-r2/test/*.test.mjs` | see "Project layout" |
| Codex version pins | the version string differs across five files | update all five, then `npm run update:codex-schema` in `agentd/` |
| production dependency stage | `scripts/stage-agentd.sh` cannot stage, smoke-import, or SBOM the locked tree | usually a lockfile or Codex-package problem |
| Swift tests | `swift test --arch arm64` exits non-zero | see "Reading swift test output" |
| Swift warning budget | a new compiler warning | below |
| localization readiness | a new untranslatable string | below |
| whitespace | `git diff --check` on your **unstaged** changes | remove trailing whitespace |

While iterating you can run one gate at a time: `swift test --arch arm64 --filter <TestClassName>`
from `app/`, `npm test` from `agentd/`, and `scripts/warning-budget.sh` or
`scripts/localization-baseline.sh` from anywhere (both resolve the repository themselves). Run
`./scripts/check.sh` before you open the PR anyway: only it runs the whole set the way CI does.

## The two ratchets

**Customer names.** Mechanician can be built for a named organization, and a customer's name written
into a comment or a test fixture ships the moment this repository publishes. That has happened, and it
came back two days after a hand sweep removed it, so it is a gate rather than a habit.

The gate almost certainly **skips** for you, and that is the design. The names it looks for are not
written down here, because a denylist in a public file is the leak it exists to prevent. They are
derived from a private tenant-configuration checkout (one directory per tenant) whose path a
maintainer supplies through `MECHANICIAN_ENTERPRISE_CONFIG`. Without that checkout there is nothing
to protect, so the gate prints `skipped` and passes. A maintainer who has it gets the check; a fork
gets a green build and learns nothing. For a trading name or acronym the directory slug does not
spell, add it to `tenant-denylist.txt` beside that configuration, or to a gitignored
`scripts/tenant-denylist.local.txt`.

If it does fire, it names the file and line. Describe the deployment rather than the customer: "a
managed Vertex deployment", not a company. For a fictional tenant in a test, the suite already uses
`Acme` and `Northwind`.

**Swift warning budget.** `cat scripts/warning-budget.txt` reads `0`, so any new compiler warning
under `app/Sources` fails the gate, which prints every offending site. Warnings exist only for
files the compiler recompiled, which is why `check.sh` and `warning-budget.sh` `touch` every source
first. There is no `--write`: when you remove warnings, lower the number by hand in the same commit
(`echo <count> > scripts/warning-budget.txt`).

**Localization baseline.** `cat scripts/localization-baseline.txt` reads `349`. The script counts
`Text(someExpression)` (the verbatim `String` overload, never localized) plus AppKit
`messageText`/`informativeText` literals. Three legitimate fixes: a SwiftUI string literal (already
a `LocalizedStringKey`), `String(localized:)` for AppKit, or `Text(verbatim:)` when the value is
user data. If it is user data and the count still rose, raise the baseline deliberately with
`scripts/localization-baseline.sh --write` in the same commit, and say why.

## Reading swift test output without being lied to

A failing run ends green. This has already cost the project a shipped regression.

```
Test Case '-[DemoTests.DemoTests testAssertFails]' failed (0.009 seconds).   <- the real signal
	 Executed 2 tests, with 1 failure (0 unexpected)   <- "(0 unexpected)" counts ONLY thrown errors
✔ Test run with 0 tests in 0 suites passed after 0.001 seconds.              <- last line, exit 1
```

That last line is swift-testing reporting on a suite that does not exist: every test in `app/Tests`
is XCTest (`grep -rl "import Testing" app/Tests` returns nothing), so it is always green. Read the
exit status, require `with 0 failures`, or `grep "' failed (" ` the output. If you pipe
`swift test`, `$?` is the pipe's status: `check.sh` reads `${PIPESTATUS[0]}`.

## Project layout

- `app/` is the SwiftPM package: `Sources/Mechanician`, a separate `MechanicianKeychainHelper`
  executable, and `Tests/MechanicianTests`. Counts move every release, so derive them rather than
  quoting them: `find app/Sources/Mechanician -name '*.swift' | wc -l`,
  `find app/Tests/MechanicianTests -name '*.swift' | wc -l`
- `agentd/` is the Node ESM daemon: `src/` and `test/`, the latter being what `npm test` runs.
  `find agentd/src -name '*.mjs' | wc -l`, `find agentd/test -name '*.test.mjs' | wc -l`
- `scripts/` holds the build, verification, and release scripts; `build-app.sh` and `dev.sh` are at
  the repository root.
- `spike/format-r2` is throwaway prototype and measurement code, but its 15 test files run in
  `check.sh` (`ls spike/format-r2/test/*.test.mjs | wc -l`). Editing it can turn CI red.
- `docs/history/` holds superseded design documents, including three ADRs for a runtime service
  that was built and then reverted. History, not current design.
- `FR-NNN` comments in Swift and Node source are opaque identifiers pointing at a maintainers'
  tracker that is not part of this repository. Ignore them, and do not add new ones.

## Making a change

Branch from `main` and open a PR against `main`. Use conventional commit subjects (`fix(scope):`,
`feat(scope):`, `docs(scope):`). This is not style preference: unless a hand-written
`docs/release-notes/<version>.html` already exists, `scripts/release.sh` builds the in-app update
notes from commit subjects since the last release commit, stripping the `type(scope):` prefix,
capitalizing the first letter, and keeping the first 20, so your subject becomes a user-visible
bullet.

`./scripts/check.sh` must pass before you open the PR. Beyond compiling, exercise the affected flow
in a running build: UI, persistence, permissions, and provider behavior break in ways the compiler
cannot see. Say how you verified it, and call out new user-facing strings, changes to persisted
models, and anything touching permissions or credentials.

Which document to read first:

| Change | Read |
| --- | --- |
| a new event or request on the app/daemon wire | [AGENTD-PROTOCOL.md](docs/architecture/AGENTD-PROTOCOL.md) |
| daemon behavior, provider turns, tool dispatch | [AGENTD-INTERNALS.md](docs/architecture/AGENTD-INTERNALS.md) |
| anything persisted to disk | [STORAGE-AND-PERSISTENCE.md](docs/architecture/STORAGE-AND-PERSISTENCE.md) |
| tools, allowlists, approval prompts | [SECURITY-AND-PERMISSIONS.md](docs/architecture/SECURITY-AND-PERMISSIONS.md) |
| windows, menus, panels, AppKit/SwiftUI seams | [APP-SHELL-AND-UI.md](docs/architecture/APP-SHELL-AND-UI.md) |
| accounts, sign-in, model selection | [PROVIDER-LANES-AND-ACCOUNTS.md](docs/architecture/PROVIDER-LANES-AND-ACCOUNTS.md) |
| scheduled or unattended work | [BACKGROUND-WORK.md](docs/architecture/BACKGROUND-WORK.md) |
| bundling, signing, entitlements | [BUILD-AND-PACKAGING.md](docs/development/BUILD-AND-PACKAGING.md) |

## What you cannot run from outside

`scripts/release.sh` is maintainer-only: it needs Developer ID Application and Installer identities
for the project's team, a notarytool keychain profile, the Sparkle EdDSA private key, and write
access to the update bucket, and it refuses to publish unless CI is green on that exact commit.
Notarized and Developer ID signed builds are therefore out of reach for a fork; with no Developer
ID Application identity present `build-app.sh` falls back to ad-hoc signing, which runs locally but
is not distributable.
`scripts/dogfood.sh` builds the production-shaped bundle without publishing, but needs the pinned
Xcode and a clean worktree (untracked files included). None of that is required to contribute:
`./dev.sh` and `./scripts/check.sh` are enough.

Maintainers can publish an opt-in Daily with `scripts/release.sh <version> --channel daily`. Daily
creates the final immutable ZIP and signed/notarized versioned DMG without moving Stable aliases.
After the documented two-machine soak, `scripts/promote-daily.sh <version> --attestation <file>`
promotes those exact bytes by changing only the signed appcast metadata; see
[BUILD-AND-PACKAGING.md](docs/development/BUILD-AND-PACKAGING.md#promoting-a-daily-build-to-stable).

## Licensing contributions

By submitting a contribution, you agree that it may be distributed under this repository's
[MIT License](LICENSE), and you represent that you have the right to submit the work under those
terms. Do not contribute code, assets, data, or documentation copied from a private or
incompatibly licensed source.

By participating you agree to the [Code of Conduct](CODE_OF_CONDUCT.md).
