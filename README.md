# Mechanician

A native macOS agentic workspace for real work, powered by Claude and OpenAI.

[Website](https://mechanician.ai/) · [Download](https://mechanician.ai/download) ·
[Help](https://mechanician.ai/help) · [Privacy](https://mechanician.ai/privacy) ·
[Changelog](CHANGELOG.md)

Mechanician pairs a fast, native Mac interface with a coding-and-computer-use agent that can read
and write files, run commands, drive a terminal, search, build artifacts, and act on your Mac. It
is organized around two nouns: **Conversations** (the spine of the work) and **Workspaces** (the
container they live in, optionally backed by a working folder). It is a full desktop app, not a
chat window: multi-provider, multi-window, and Mac-assed by design.

> **Heads up:** Mechanician runs agents that can execute shell commands, control your computer,
> and (opt-in) run unattended. Read [SECURITY.md](SECURITY.md) before enabling those surfaces.

## Architecture

The app side (`app/`) is native Swift, not Electron or a web-view wrapper. AppKit owns the shell and
the behavior-sensitive surfaces: windows and tabs, toolbars, transcript scrolling and row reuse,
text input, and the Agents inspector. SwiftUI is used for content inside that shell. The agent does
not run in the app; the app drives `agentd`, a headless Node daemon (`agentd/`), over
newline-delimited JSON on the child process's stdin and stdout. The agent engines stay on Node
because the provider SDKs are Node libraries. `AgentdRuntime` in
`app/Sources/Mechanician/AgentdRuntime.swift` owns the transport.

Each workspace window owns an `AgentBridge`, and each bridge runs one agentd process per provider
lane it uses (`private var runtimes: [ModelAccess: AgentdRuntime]` in `AgentBridge.swift`). A
Claude subscription turn and an OpenAI API turn therefore never share a process or a credential.
Four lanes ship in the public app, listed as `ModelAccess.builtInCases` in
`app/Sources/Mechanician/ProviderAccountStore.swift`: Claude subscription, Anthropic API, Codex
subscription, and OpenAI API. Two more, Claude through Google Vertex AI and Claude through AWS
Bedrock, exist in the enum but activate only when a signed enterprise profile declares those
routes. The standard app can import that profile, and managed Macs can receive it through MDM;
without one, the routes are inert.

agentd in turn launches the provider's own engine as a child process: the Claude Agent SDK's
bundled `claude` executable, or the OpenAI Codex App Server (`codex app-server --stdio`).
Scheduled and triggered runs happen in a third program, `ambientd` (`agentd/src/ambientd.mjs`). An
enabled task on an eligible API-key or managed route starts the scheduler as an app child while
Mechanician is open. The separate **Run when closed** setting is opt-in and installs ambientd as a
launchd LaunchAgent so it keeps running after you quit. Scheduled work is read-only by default;
full Mac access is a separate explicit choice.

**Read [docs/architecture/OVERVIEW.md](docs/architecture/OVERVIEW.md) first.** It is the map of
which file to open. The rest of the set:

- [AGENTD-PROTOCOL.md](docs/architecture/AGENTD-PROTOCOL.md): the NDJSON request/event contract
  between the app and the daemon.
- [AGENTD-INTERNALS.md](docs/architecture/AGENTD-INTERNALS.md): how the daemon is put together.
- [STORAGE-AND-PERSISTENCE.md](docs/architecture/STORAGE-AND-PERSISTENCE.md): where conversations,
  workspaces, artifacts, and attachments live on disk.
- [SECURITY-AND-PERMISSIONS.md](docs/architecture/SECURITY-AND-PERMISSIONS.md): tool approval,
  allowlists, and what an unattended run may do.
- [APP-SHELL-AND-UI.md](docs/architecture/APP-SHELL-AND-UI.md): the AppKit/SwiftUI boundary and the
  window model.
- [PROVIDER-LANES-AND-ACCOUNTS.md](docs/architecture/PROVIDER-LANES-AND-ACCOUNTS.md): lanes,
  credentials, and account state.
- [BACKGROUND-WORK.md](docs/architecture/BACKGROUND-WORK.md): the ambient scheduler, subagents, and
  workflows.
- [docs/development/BUILD-AND-PACKAGING.md](docs/development/BUILD-AND-PACKAGING.md): how a
  release bundle is assembled, pinned, signed, and verified.
- [docs/adr/](docs/adr/): accepted architecture decision records.

## Features

- **Multi-provider.** Claude (Anthropic Agent SDK) and OpenAI/Codex, chosen per conversation
  from an in-app model picker, with per-provider account management.
- **Conversations and Workspaces.** A persisted, searchable conversation library with All, Unread,
  and Working filters, pinning, and bulk actions. Workspaces can be folderless or folder-backed; a
  folder lights up files, Git, builds, and the working terminal. One workspace maps to one native
  tab group, with its conversations as tabs.
- **Streaming transcript** with multi-turn continuity (session resume), interrupt, prompt
  queueing, steering, and history replay if a stored session expires.
- **Tool visibility and permissions.** See each tool call and result; approve or deny inline
  against Mechanician's own per-workspace allowlist.
- **Artifacts.** The agent builds HTML, SVG, Mermaid, CSV, and Markdown into a live preview pane and
  native artifact browser. Mermaid is laid out with a pinned bundled renderer, sanitized, frozen to
  SVG, and displayed under the same script-free policy as other agent-authored previews. You can
  move artifacts between workspaces, bulk-organize the library, drag one back into the composer to
  revise it, or export or share it as a normal file (including rendered PDF for HTML).
- **Durable attachments.** Images and arbitrary files are copied into their conversation, retain
  their names and Quick Look previews, can be reordered alongside authored text, and stay intact
  when a mixed text-and-file selection is copied into another conversation.
- **Changes panel.** Git status, stage and unstage, colored diffs, commit, and push, plus durable
  per-conversation work records that distinguish this conversation, other conversations sharing
  the repository, and the current worktree.
- **Terminal.** A real PTY-backed shell (node-pty + SwiftTerm) in the working folder.
- **Ambient scheduler.** Scheduled and triggered runs (time, file-watch, and mail), using eligible
  API-key or managed routes. They run read-only by default; running after app quit and granting full
  Mac access are independent opt-ins.
- **Extensions.** Browse curated MCP registries, configure remote or local servers on Claude and
  Codex lanes, and install Claude or Codex plugins from curated or user-added marketplaces.
- **MCP interaction.** OAuth and Keychain-backed credentials plus attributed forms,
  confirmations, and URL prompts when a server needs input mid-turn.
- **Computer use and Apple automation.** Drive apps through Accessibility, AppleScript/JXA, and
  approved Shortcuts; expose Mechanician's own actions to Shortcuts and Siri; preserve a useful
  automation as a reusable capability.
- **Workflows and subagents.** Multi-agent orchestration with a live tree, observed current-step
  cards, and retained Trace, timing-based Path, and provider-reported Usage views for parallel work,
  waits, tools, tokens, and context.
- **Voice input.** On-device-first dictation into the composer, with a system speech-recognition
  fallback when the local model is unavailable.
- **Spotlight.** Conversations and artifacts are indexed and openable from Spotlight.
- **Built-in Help.** A dedicated Help workspace answers from a signed, build-matched guide, can
  present reviewed walkthroughs, and shows a live inventory of the current conversation's tools,
  skills, connections, and saved automations.
- **Signed updates** via Sparkle, with manual checks as the network-quiet default and automatic
  checks available as an opt-in.

## Requirements

**To run Mechanician** (a downloaded release), no separate installs are required:

- **macOS 26 (Tahoe) or later**, a hard minimum. Release builds use the exact audited macOS SDK
  pinned in `build-app.sh` and cannot launch on earlier versions.
- **Apple Silicon (arm64).** The release is Apple-Silicon-only.
- A **Claude** subscription or Anthropic API key, and/or a **Codex** subscription or OpenAI API key.

That's it. The release bundles its own Node runtime and pinned Claude and Codex engines, so **you
don't need Node, Codex, Claude Code, or the ChatGPT desktop app installed**. The Changes panel has a
built-in Git reader, so **you don't need Xcode or the Command Line Tools** to see status and diffs.
(Command Line Tools are still needed to stage, commit, or push, and for the *agent* to run
`git`/`xcodebuild` itself; the app offers an install prompt when needed.)

Optional command-based MCP servers may require the runtime named in their displayed launch command
(for example, `uvx` or Docker). npm-based servers use Mechanician's bundled, pinned Node/npm runtime.
Mechanician always shows the exact command and asks before recording or starting a local server.

**To build from source**, additionally:

- **Xcode** with **Swift 6.2 or later**, Apple Silicon. `build-app.sh` refuses to run unless
  Xcode and the macOS SDK match the exact pins recorded there. `dev.sh` does not pin: it selects the
  newest macOS SDK it finds under `/Applications/Xcode*.app`, so a dev build exercises the newest OS
  features. Set `MECHANICIAN_DEVELOPER_DIR` to override that choice.
- **Node.js 24 or later** and `npm ci` in `agentd/`. A dev build uses your system Node; release builds
  download and checksum-verify a pinned Node automatically via `build-app.sh`.

## Develop

```bash
cd agentd && npm ci && cd ..          # install the exact locked daemon dependencies
./dev.sh                              # swift build, then assemble and launch a dev .app bundle
```

`dev.sh` does not use `swift run`. It runs `swift build` and wraps the debug binary in a real
`.app` bundle so the dev build has a Dock icon, a bundle identity, and working App Intents. That
bundle is deliberately a separate identity from the installed app: bundle id `ai.mechanician.app.dev`,
its own support directory, its own `mechanician-dev://` URL scheme, and no Sparkle keys.

`dev.sh` defaults to subscription auth rather than a metered key, but it exports its own
`MECHANICIAN_CONFIG_DIR`, so the dev build does **not** inherit an existing `~/.claude` login. It
starts signed out. Sign in inside the dev app: **Window ▸ Providers** (Cmd-Option-A). For metered
Anthropic API-key mode, it resolves `ANTHROPIC_API_KEY` from env, then the macOS Keychain (account
`mechanician`, service `ANTHROPIC_API_KEY`), then `agentd/.env`, and sets the agent's working
directory. See [CONTRIBUTING.md](CONTRIBUTING.md) for getting a first turn to run, including the
mock lane.

Run `./scripts/check.sh` before opening a PR. It is what CI runs.

Before a public release, exercise the production-shaped bundle locally:

```bash
./scripts/dogfood.sh             # package + sign + verify packaged Claude auth
./scripts/dogfood.sh --install   # also replace /Applications/Mechanician.app and relaunch
```

Unlike `dev.sh`, this requires a completely clean worktree and uses the locked production
dependencies and bundled provider engines. It deliberately skips notarization, DMG/appcast work,
uploads, commits, and tags.

`--install` replaces and relaunches `/Applications/Mechanician.app`; run that form from a plain
Terminal rather than from inside the app being replaced.

## Build a signed app

```bash
./build-app.sh                                        # Developer ID signed (or ad-hoc)
MECHANICIAN_NOTARY_PROFILE=<profile> ./build-app.sh   # + notarize + staple
```

`build-app.sh` verifies the pinned Xcode and macOS SDK versions before assembling an artifact.
Without the project's Developer ID identity it falls back to ad-hoc signing for local use.
`scripts/release.sh` is maintainer-only; it cuts and publishes a signed, notarized release to the
Sparkle appcast. Details are in
[docs/development/BUILD-AND-PACKAGING.md](docs/development/BUILD-AND-PACKAGING.md).

## Documentation

- [docs/architecture/OVERVIEW.md](docs/architecture/OVERVIEW.md): start here to change the code.
  The full architecture set is linked from the [Architecture](#architecture) section above.
- [CONTRIBUTING.md](CONTRIBUTING.md): setup, the checks a PR must pass, and how changes flow.
- [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md): expected conduct for participants.
- [CHANGELOG.md](CHANGELOG.md): user-facing changes per release.
- [docs/GUIDE.md](docs/GUIDE.md): the complete guide to the mental model, with a tour of every
  menu, control, and surface.
- [docs/FEATURES.md](docs/FEATURES.md): a capability overview.
- [Mechanician Help](https://mechanician.ai/help): the full task-oriented web guide.
- [docs/CODEX-LIFECYCLE-DIAGNOSTICS.md](docs/CODEX-LIFECYCLE-DIAGNOSTICS.md): the redacted Codex
  diagnostics export, fault matrix, soak command, and release-candidate checklist.
- [docs/history/](docs/history/): superseded plans and decision records, kept because they explain
  why the current shape was chosen. The Runtime Service most of them describe was built, shipped as
  0.10.0, and reverted the next day. Nothing there describes how the app works now. Read
  [docs/history/README.md](docs/history/README.md) before any file in it.

## Repo layout

- `app/`: native Swift macOS app (AppKit shell with SwiftUI content; SwiftPM package)
- `agentd/`: headless Node agent daemon (provider SDKs + git + pty)
- `help/`: reviewed source for the signed, build-matched in-app Help corpus
- `spike/`: throwaway prototype work, kept in the repo for its measurements rather than its code.
  Nothing in it ships. Its tests still gate CI: `scripts/check.sh` runs
  `node --test spike/format-r2/test/*.test.mjs`, so a change that breaks the spike fails the build
  like any other.
- `build-app.sh`: assemble a signed (and optionally notarized) `Mechanician.app`
- `dev.sh`: development launcher
- `scripts/check.sh`: the canonical verification command, and what CI runs
- `scripts/dogfood.sh`: signed production-shaped build and packaged-auth check
- `scripts/`: release, DMG, and update-publishing tooling
- `docs/architecture/`, `docs/development/`: how the system works and how it is built
- `docs/adr/`: accepted architecture decision records
- `docs/history/`: superseded plans and reverted decisions
- `docs/release-notes/`: per-release notes, published via Sparkle

## Contributing

Read [CONTRIBUTING.md](CONTRIBUTING.md), then run `./scripts/check.sh` before opening a PR.
Participation is governed by the [Code of Conduct](CODE_OF_CONDUCT.md).

## Security

Mechanician executes tools with real side effects and supports unattended and explicit full-access
modes. Please read [SECURITY.md](SECURITY.md) for the threat model and how to report a vulnerability.

## License

MIT, see [LICENSE](LICENSE). © 2026 Magic & Lasers.

Third-party components are listed in [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).
