# Mechanician — Features

*A native macOS agent workbench from [Magic & Lasers](https://magicandlasers.com) that runs both
Anthropic and OpenAI — subscriptions and API keys — side by side, in a real Mac app.*

## The one-sentence thesis

Mechanician is a true native Mac application that runs **both** Anthropic and OpenAI —
subscriptions **and** API keys — side by side, with an opinionated structure and deep macOS
integration. Native correctness isn't a coat of paint here; it *is* the product.

## 1. One app, both providers — four account lanes

Mechanician talks to four independent account "lanes" at once:

- **Claude subscription** (your Claude Code login)
- **Anthropic API** (your API key)
- **Codex / ChatGPT subscription** (your ChatGPT login)
- **OpenAI API** (your API key)

Those four ship in every build. The `ModelAccess` enum in `AgentBridge.swift` actually defines six
lanes; the extra two are managed Claude routes (Vertex AI and AWS Bedrock) that exist only when a
signed enterprise profile declares them, and `builtInCases` in `ProviderAccountStore.swift` is what
the public app sees.

```
$ awk '/^enum ModelAccess/,/^    var maker/' app/Sources/Mechanician/AgentBridge.swift \
    | grep -c '^    case '
6
```

Each conversation picks its own model. Lanes run in the background and stream **turns
concurrently — one per conversation** — so a long Claude turn in one thread doesn't block a Codex
turn in another; each carries its own session and working directory and runs truly in parallel.
You can hold a Claude conversation and a Codex conversation open at the same time and even hand a
task from one to the other. Both the *subscription* and the *API-key* path are supported for each
vendor, with in-app sign-in for both.

The **Providers** window is the single management surface for those lanes. It can also import a
signed enterprise configuration into the standard app, adding a managed route such as Claude on
Vertex AI and managed extension catalogs without creating a separate app build or update channel.
For enrolled enterprise Macs, the same signed profile plus provider, permission, scheduling,
extension, and update restrictions can be delivered automatically as a forced MDM managed
preference.

## 2. A genuinely native Mac app

Mechanician is a native Swift macOS application with an AppKit-owned shell. AppKit owns the window,
menu, panel, tabbing, and scrolling behavior; SwiftUI is used for content views where it fits that
native shell. That buys correctness:

- Real macOS window model, menus, and multi-window behavior
- Native scrolling that stays pinned correctly under streaming (a single AppKit scroll authority)
- Full accessibility — every icon-only control carries an explicit VoiceOver label (an app-wide
  convention, not an afterthought)
- Native surfaces, pickers, text, and performance
- Sparkle 2 signed updates with manual checks as the network-quiet default and automatic checks as
  an opt-in; every release build is Developer-ID signed, notarized, and stapled

## 3. Two nouns — Conversations and Workspaces

Mechanician's structure is deliberately tiny. The whole model is **two nouns**:

- **Conversation** — one chat with Mechanician. It's the primary surface in *every* window,
  always.
- **Workspace** — a place your conversations live. You always start in **Home**, the default
  workspace (loose chats, nothing to set up); you create more workspaces for specific work. A
  workspace **with a folder** lights up git, build, and files, and points the terminal and every
  turn at that folder; one **without** a folder is a chat-and-artifacts space (its terminal and
  turns run in your home directory). That's the only fork — a property of the workspace, never a
  mode you toggle.

**Home is a workspace — the default one**, not a separate kind of thing; a casual user can live in
Home forever. One workspace = one top-level native tab group; its conversations are the tabs.
Workspaces keep their conversations, files, and standing instructions together; conversations move
between workspaces by dragging them onto another workspace's window, bringing their artifacts with
them; and any workspace can gain or change its folder later, with guarded migration that never loses
a conversation or mis-points a window.

**No modes.** Coding isn't a sub-product you switch into — it's just what a conversation *does*
when its workspace has a folder. The user talks; the agent reaches for build, terminal,
computer-use, automation, or artifacts as the task demands. Power scales; the surface never
fragments.

## 4. Agentic coding as a native GUI

When a workspace has a folder, its conversations quietly gain a full agentic-coding surface on top
of Claude Code and Codex — no mode to switch into, just the panels a terminal CLI can't render
well:

- An **embedded terminal** (SwiftTerm)
- A live **Changes panel**: git status and diffs that auto-refresh while the agent works, with a
  per-conversation work record. A checkout is usually shared, so the panel separates this
  conversation's work from the other conversations linked to the same repository, says how each
  file was learned (a file tool, a Git observation, or observed while running and unverified),
  and opens any entry to the transcript entry, digests, and captured patch behind it. It refuses
  to read a clean worktree as proof that work reached a branch.
- A **permission approvals** UI for tool calls, with per-tool allow/always/deny and isolation per
  turn
- **Build integration** that returns structured diagnostics
- An **Inspector / preview split** for artifacts and files

## 5. Fine-grained turn control — steering, queue, interject, cancel

While a turn is running you can:

- **Steer** it — inject guidance that the provider ingests at its next natural boundary, shown
  inline as it's delivered
- **Cancel** an in-flight steer you sent by mistake (with a best-effort retraction to the runtime)
- **Queue** a message to run after the current turn, or **interject** (`/btw …`) to interrupt now
  and auto-resume the original
- Guidance patience is bound to *turn liveness*: a steer survives a long, busy turn and only falls
  back to the durable queue on turn-end, lost connection, or genuine silence
- When steering genuinely isn't possible, the composer *explains why* rather than silently queueing

## 6. Multi-agent orchestration — Workflows

Mechanician can run deterministic multi-agent workflows: fan out subagents in parallel, pipeline
work through stages, verify findings adversarially, and synthesize — including **cross-provider
delegation**, where one provider's agent hands scoped work to another. It's a programmable
orchestration layer surfaced as native, observable run cards with live progress, not just a single
chat loop. The Agents inspector preserves the delegated-agent tree and lets you drill into any
agent's prompt, result or error, model, timestamps, token and tool counts, and tool-by-tool
timeline. A retained whole-conversation summary folds the root and every delegate into one view;
cards surface the fields that were actually observed, including current step, optional target, time
in step, and tool mix while an agent runs.

The resizable Activity pane turns the same work into an execution profile. **Trace** aligns the
root and reported delegate activity on one clock, including model work, tools, waits, native
compaction, provider-visible history reduction, user guidance, terminal states, and token volume;
**Path** marks a timing-based chain calculated from temporal overlap. **Usage** plots
provider-reported token activity, breaking out new input, generated output, and cached input when
that detail is available, while plotting root-context pressure and compaction against the
provider-reported window when available. Turn history, per-agent filters, pinned inspection, and
Trace's span-by-span keyboard and VoiceOver navigation make delegated results auditable during the
run and afterward.

## 7. The Mac is the platform — deep macOS automation

Mechanician treats macOS itself as the surface to act on, all gated by explicit approval:

- **AppleScript / JXA** to drive any scriptable Mac app (Mail, Finder, Notes, Calendar, Reminders,
  Messages, Safari, System Events…)
- **Computer use** — it can see the screen and click/type/scroll/drag/launch apps, plus read the
  Accessibility tree to target controls reliably
- **App Intents in both directions** — Mechanician exposes its *own* intents to Shortcuts/Siri,
  *and* it can run the user's Shortcuts to reach app actions
- **Saved capabilities** — a working automation can be saved as a named, reusable, one-time-approved
  tool for a given app

## 8. Artifacts and a live preview pane

A native preview pane renders artifacts live, including a global artifacts view across
conversations, without cluttering the chat. HTML pages, dashboards, and SVG render in a
script-free `WKWebView`; CSV renders as a native table; Markdown renders natively. Mermaid renders
as a diagram without making the preview a place where agent-authored code runs: a pinned, bundled
copy of Mermaid lays the diagram out in a throwaway offscreen web view, the result is sanitized and
frozen to SVG, and what reaches the screen is markup under the same `script-src 'none'` document as
every other artifact (`MermaidRenderer` in `app/Sources/Mechanician/MermaidRenderer.swift`). A
diagram that fails to parse falls back to its escaped source with Mermaid's own error. Artifacts
are durable, editable objects rather than disposable previews:

- Drag one into the composer to give the agent its current source and revise the same artifact.
- Drag one to Finder for a normal file, or use Share, Save to File, Copy Source, Open in Default
  App, Reveal in Finder, and rendered HTML-to-PDF export.
- Drag supported files back into either Artifacts view to import them.
- Pop an artifact into its own live window while the conversation continues.
- Move one or a multiple selection to Home, an existing workspace, or a newly created workspace;
  the conversation link remains intact.
- Use native range/multiple selection and bulk Favorite, Move, and Delete in the global library,
  with Favorite, Rename, and Delete parity in the conversation inspector.

Files coming into a conversation are durable too: images and arbitrary document types are copied
into conversation-owned storage, shown as named Quick Look-backed previews in both the composer and
transcript, and can be reordered around authored text with Undo/Redo. Copying a mixed selection into
another conversation preserves its order and gives the destination its own copies.

## 9. Extensions — MCP plus plugin marketplaces

**Extensions** is three destinations because the formats really are different:

- **MCP Servers** works on Claude and Codex lanes. Browse the enabled vendor-curated registries
  (Microsoft Azure and GitHub by default), grouped by source; filter remote, local, or first-party
  entries; inspect configured server status and provenance; or add an exact HTTP endpoint or local
  command by hand.
- **Claude Plugins** browses Anthropic-style marketplaces and HTTPS archive registries added by the
  user or an organization. It shows the named skills, commands, agents, hooks, and MCP servers a
  plugin contains, reports its always-on context cost, and supports install, disable, update, and
  uninstall.
- **Codex Plugins** browses OpenAI's large remote catalog and local marketplaces with search and
  category filters, full publisher/service details, install, and removal.

MCP authentication happens in-app and is scoped to the selected provider lane, with credentials in
the macOS Keychain. A configured server can ask an attributed question mid-turn — confirmation,
typed form, choice, or full HTTPS URL — instead of being silently declined. Claude-owned
claude.ai connectors remain visible on Claude lanes. Changes take effect on the next message.

Provider **account** management lives in a separate Providers window, with in-app subscription
OAuth and Keychain-stored API keys. **Provider-access request cards** preserve a task when it needs
the other vendor's family and let the user choose subscription or API key before it resumes.

## 10. Ambient & scheduled agents

Mechanician can run scheduled "routine" agents and support ambient, event-driven work (time,
file-watch, or new-mail triggers).

**What is opt-in, precisely.** Running tasks *after you quit* is opt-in: the **"Run when closed"**
switch installs a launchd LaunchAgent, and nothing schedules work outside the app until you turn it
on. Running tasks *while the app is open* is not opt-in. Once a task is enabled, assigned to a
workspace, and its lane has a credential, the app starts the scheduler as a child process without
further consent (`shouldRunInProcess` in `app/Sources/Mechanician/AmbientStore.swift`). Unattended
runs also need a metered provider route: an API-key lane in the standard app or an eligible managed
Vertex route. Subscription access may not run unattended, so a subscription-only install has no
way to schedule anything.

**Unattended runs are read-only by default, not trust-all.** A scheduled task's tool list is capped
at reading and artifacts, so it cannot edit files, run shell commands, or drive other apps: the
Claude path pins `allowedTools` to `Read`, `Glob`, `Grep`, and the artifacts tool (`runTaskViaSdk`
in `agentd/src/ambientd.mjs`), and the lanes that run through agentd are filtered to the read-only
set by `unattendedToolSpecs` / `unattendedToolAuthorization` in
`agentd/src/runtime-policy.mjs`. Tools that need a person present
(questions, wait-mode, Shortcuts, AppleScript, saved capabilities, computer use) are withheld from
the tool list entirely rather than offered and then denied. Full access exists but is an explicit
choice: the task editor's **Access** picker offers "Read-only workspace access" and a **Trust all**
option labelled "full Mac access", and only the second lifts the cap. Tasks the agent schedules on
your behalf are forced back to read-only whatever the model asked for (`createFromAgent` in
`AmbientStore.swift`).

## 11. Wait-mode — no hallucinated waiting

When work depends on a real external event (a build/notarization/deploy finishing, CI going green,
a file appearing, a delay elapsing), Mechanician arms a **WaitFor** trigger with a ⏳ indicator and
an in-app watcher that automatically resumes the agent when the event fires — instead of the model
falsely claiming it will "keep an eye on it."

## 12. Local-first — your credentials, your data

- Runs on your Mac, under your accounts; API keys live in the **Keychain**
- Conversations are stored locally; a hard invariant is that relaunch/upgrade must **never appear
  to lose conversation state** (last-open workspace/conversation is restored)
- One shared conversation store backs all windows, so state stays consistent across the app

## 13. Help that describes this conversation

**⌘?** opens task-oriented guides inside the app. Beside them, **What it can do** is a live
inventory for the exact selected conversation and accepted provider turn. During an active turn,
its captured permission mode and tool surface remain authoritative even if the toolbar already
shows a different choice marked **NEXT**. After the turn completes, changing the conversation,
workspace, provider/account route, profile, permission mode, or runtime makes its last-observed
evidence ineligible. The inventory is advisory, not an authorization boundary or a ceiling on what
the user can ask.

**Ask Mechanician** opens a durable folderless Help conversation. Its closed expert profile exposes
exactly signed Help search and bounded signed guides in Plan, plus the app-owned bounded operation
vocabulary outside Plan: no files, shell, web, extensions, or arbitrary Mac automation. Ask it to
**show me** a supported feature and it can start an exact signed guide, and most of those guides
leave Help. A conversation guide presents the
Changes, Agents, Artifacts, Skills, and Files inspector tabs and the model, reasoning effort,
permission, and message-box controls in the person's own conversation window, without opening a
workspace to do it. It accepts no coordinates, selectors, or a
destination from the provider, and a tab the guide had to reveal is put away when it ends.

Asking for the app to be **operated** rather than shown runs the same boundary one step further. The
agent opens inspector tabs and app windows, focuses the message box, starts an empty conversation,
and sets the conversation's model or reasoning effort, all from a closed vocabulary the app owns. A
model or effort target is re-resolved against what the account actually reported. The vocabulary
contains no operation for permission mode, account connection, sending, or deletion, so operating
the app cannot widen what the agent may do next; it is refused outright in Plan mode and withheld
from scheduled tasks.

Turning a configured connection on or off is the one operation that stops and asks. That setting is
shared by every conversation, so Mechanician shows a card composed from its own state — what is true
now, what would become true — and nothing changes until the person confirms. The call waits for
them rather than timing out, a decline is reported as their decision, and a turn that ends under an
unanswered card is reported as unanswered rather than as a refusal.

Reviewed **Try workflow** actions are the separate automation path. They create an unsent standard-
conversation draft; after the user sends it, `RecommendMechanicianWorkflow` assesses that exact
signed recipe against the accepted turn. Its app-owned label says **Ready to try here**, **Switch
out of Plan**, **Not available in this conversation**, or **Not verified yet**; every non-ready
label stops the demonstration. The assessment never pre-approves an action; confirmation, provider,
app, sandbox, and macOS permission checks still apply.

Skills also have a conversation-scoped Inspector tab, grouped by the plugin that supplied them.
Selecting one arms it for the next message. Saved Mac capabilities appear as runnable in Help only
when the exact route reports `RunCapability` and its accepted mode permits execution.

## The shape, in one paragraph

Mechanician is the native Mac workbench that unifies both vendors: both subscriptions and keys,
running in parallel, inside a real Mac app with an opinionated structure, a full agentic-coding
GUI, fine-grained turn control, multi-agent orchestration, and a deep macOS automation surface —
with your credentials and history staying on your machine. It's the app you reach for when you want
the best model for *this* task, acting on *your* Mac, without leaving one focused, native surface.

---

*See [GUIDE.md](GUIDE.md) for the complete tour of every menu, control, and surface.*
