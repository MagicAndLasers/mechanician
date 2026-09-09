# Security Policy

Mechanician runs autonomous agents that can execute shell commands, edit files, drive a
terminal, control your computer, and (when you opt in) run unattended. That is the point of the
app, and it is also its main security surface. This document describes the threat model, the
controls, and how to report a vulnerability.

For the enforcement architecture (where each decision is made, in which process, and what a change
there can break), see
[docs/architecture/SECURITY-AND-PERMISSIONS.md](docs/architecture/SECURITY-AND-PERMISSIONS.md).

## Reporting a vulnerability

**Please report privately. Do not open a public issue for a security bug.**

Use GitHub's **private vulnerability reporting**: open this repository's **Security** tab and
click **Report a vulnerability** (Security ▸ Advisories ▸ Report a vulnerability). That opens a
private advisory visible only to the maintainers.

Include the version (Mechanician ▸ About), your macOS version, and the smallest reproduction you
can. We aim to acknowledge within a few business days and will keep you updated as we
investigate and ship a fix. Please give us a reasonable window to release before public
disclosure.

## Supported versions

Mechanician ships as a rolling release with signed in-app updates through Sparkle. Manual checks
are the default; users can opt in to automatic checks. Only the **latest released version** is
supported; please update before reporting.

## Threat model

Mechanician's trust boundary is: **you trust the models and the prompts you run, and the tools
you approve.** Fixes and hardening focus on making sure nothing crosses that boundary without
your consent.

Surfaces to be aware of:

- **Tool execution.** The agent can run `bash`, read/write files, and use a PTY-backed shell in
  the working folder. "Calls that aren't allow-listed prompt for approval" is not the whole
  story: read-only and app-owned tools auto-allow with no prompt at all. On the OpenAI and Codex
  lanes that set is `READ_ONLY_TOOLS` in `agentd/src/runtime-policy.mjs`; on the Claude lane it is
  `isClaudeBuiltInAutoAllow()` in the same file (artifacts, wait-mode, questions, provider-access
  requests, `Skill`, `ToolSearch`, the *listing* side of Shortcuts, and both listing and **saving**
  a capability). Note the last one: `mcp__capabilities__SaveCapability` is in
  `CLAUDE_SAFE_EXACT_TOOLS`, so an agent can write a new AppleScript/JXA automation definition into
  the capability store without a prompt. *Running* one is separate and still prompts per capability
  (`RunCapability` is deliberately excluded from the auto-allow set).
  Everything else prompts unless the per-provider, per-workspace allowlist already remembers it.
- **Two enforcement points, not one.** `makeCanUseTool()` in `agentd/src/agentd.mjs` gates the
  Claude lane through the SDK's approval hook. The OpenAI Responses lane has no such hook: the
  model asks Mechanician to run functions and Mechanician runs them, so `authorizeOpenAITool()` in
  the same file is the only gate there, with no provider-side policy behind it. The two lanes do
  not enforce identical controls (see the next three items), so check which lane a control lives
  on before assuming it applies everywhere.
- **Write containment (interactive Claude turns).** `Edit` / `Write` / `NotebookEdit` carry an
  absolute path, so the target is resolved and checked before the write. A write landing outside the
  workspace root (and outside the system temp directory) prompts even in `bypassPermissions`, and even
  when the tool itself is already always-allowed. This gate is **interactive-only**: a prompt is its
  whole mechanism, and an unattended run may never prompt. `escapingWriteTarget` has no call site in
  `agentd/src/ambientd.mjs`, so a scheduled task on the `anthropic_api` or `claude_vertex` lane has no
  write containment. What protects those runs instead is the read-only default profile: `Edit` and
  `Write` are not in their tool list at all unless the task's author selected **Trust all**, which is
  the setting that removes this boundary. See `escapingWriteTarget()` in
  `agentd/src/write-containment.mjs` and the containment check at the top of `makeCanUseTool()`.
  It is deliberately **not** attempted for `bash`: a shell command can reach the same file through
  `$HOME`, a variable, or a path recorded turns earlier, and a gate routed around by accident is
  not a gate. The OpenAI lane solves the same problem differently: `openAIProjectPath()` in
  `agentd/src/agentd.mjs` throws for any file-tool path outside the workspace root, resolving
  symlinks first, so there is nothing to approve. Its `Bash` tool has no such containment.
- **The `write-outside:` grant class.** Granting "always allow" to an escaping write records a key
  of the form `write-outside:<parent folder>` in the same per-workspace allowlist as tool grants
  (`writeEscapeAllowKey()` in `agentd/src/write-containment.mjs`). Grants are remembered per
  containing folder, not per file. The key appears verbatim in Settings ▸ Permissions and is
  removable there. When you audit that list, entries beginning `write-outside:` are folders
  outside the workspace that the agent may now write to without asking.
- **Credential-store read denial (Claude lane).** Requests that name a known credential store are
  denied outright, ahead of permission mode and ahead of any remembered grant, because returning
  those bytes into model context is a data leak rather than an approval question.
  `credentialStoreReadDenial()` in `agentd/src/runtime-policy.mjs` inspects `Read`, `Grep`, and
  `Bash` inputs for `~/.claude.json`, Google application default credentials, `~/.aws/credentials`,
  `~/.netrc`, `~/.npmrc`, `~/.pypirc`, `~/.ssh/id_*`, `security find-generic-password` /
  `dump-keychain`, and the process table (`ps`, `pgrep -af`), which carries live bearer tokens on
  provider CLI command lines. Two honest limits: it is a pattern list, so it is best-effort
  against an agent that is trying to get around it, and it is wired into the two Claude enforcement
  points only, `makeCanUseTool()` for interactive turns and `ambientCanUseTool()` in
  `agentd/src/ambientd.mjs` for unattended direct-SDK runs, so the OpenAI lane's `Bash` tool does not
  go through it. On the unattended path it is the *only* gate: `ambientCanUseTool` denies a credential
  read and allows everything else.
- **`bypassPermissions` mode.** You can grant a conversation full, un-prompted tool access. Only
  use it in a directory and with prompts you trust. In an interactive Claude turn it does not lift
  the two boundaries above: credential-store reads are still denied and escaping writes still prompt.
  An unattended run is not an interactive turn; see the write-containment note above.
- **Computer use & Apple automation.** With the OS-level Accessibility / Screen Recording /
  Automation grants, the agent can see the screen and drive other apps via the accessibility
  API, AppleScript/JXA, and your Shortcuts. These are gated by macOS's own permission prompts.
- **Ambient (unattended) runs.** Scheduled/triggered agent turns run with no one watching. The
  default profile is read-only (file reads and search, plus the artifacts tool) and "Trust all" is
  an explicit per-task choice, so an unattended task cannot edit files or run commands unless
  someone chose that; see `unattendedToolSpecs()` in `agentd/src/runtime-policy.mjs` and the
  `allowedTools` cap in `runTaskViaSdk()` in `agentd/src/ambientd.mjs`. An inbox trigger feeds
  untrusted third-party email into a prompt; Mechanician fences that content as untrusted data,
  but you should still scope unattended tasks narrowly and review what they can do.
- **Prompt injection.** Content the agent reads (web pages, files, emails, tool output) may try
  to steer it. Approvals for side-effectful tools are the backstop; keep them on for untrusted
  inputs, and prefer least-privilege working directories.
- **MCP servers & connectors.** Third-party MCP servers you add run with the daemon's access.
  Only connect servers you trust.
- **Credentials.** API keys, MCP environment secrets, and MCP authorization headers live in the
  macOS Keychain; `extensions.json` contains only endpoint-bound references. Provider-owned OAuth
  state remains in the provider's credential store; Mechanician gives Codex its own home directory
  and, when a Claude subscription lane is enabled, uses Anthropic's official Claude Code login.
  Keychain storage protects credentials at rest; it is **not** a sandbox boundary against an agent
  that you authorize to run unrestricted commands as your macOS user. Such a command can potentially
  reach credentials and other data available to that user, and local MCP servers conventionally
  receive their configured credentials in their own process environment. None of these credentials
  belong in the repo. The Sparkle update feed is verified with an EdDSA public key shipped in the
  app; the private signing key is not in the repo.

## Not part of the attack surface: `agentd/src/mac-bridge`

Reading the source you will find an OAuth-authenticated MCP server at `agentd/src/mac-bridge` that
exposes `list_shortcuts`, `run_shortcut`, and `ask_on_device` over loopback. It is a development
fixture, kept because it is the only OAuth-speaking MCP server we control and therefore the test
target for MCP auth work. Nothing in `app/Sources` references it, it never registers itself as an
MCP server, and `build-app.sh` deletes it from the bundle
(`rm -rf "$APP/Contents/Resources/agentd/src/mac-bridge"`), so it cannot be reached from an
installed app. It only runs if you start it by hand from a working tree. See
`agentd/src/mac-bridge/README.md`.

## Hardening you can do

- Run agents in the narrowest working folder that fits the task.
- Keep tool-approval prompts on for any conversation that reads untrusted content.
- Reserve `bypassPermissions` and unattended/ambient runs for trusted, well-scoped tasks.
- Treat unrestricted shell access as access under your macOS identity, not as a sandboxed build
  container. Use a separate macOS account or VM when the work itself is untrusted.
- Review the per-workspace allowlist (Settings ▸ Permissions) periodically, and pay particular
  attention to `write-outside:` entries: each one is a folder beyond the workspace that the agent
  may write to unprompted.

Thank you for helping keep Mechanician users safe.
