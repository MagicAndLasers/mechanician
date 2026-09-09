# The Mechanician Guide

*A complete guide to Mechanician — the mental model first, then every menu, control, and surface
in the app. Mechanician is a native macOS agent workbench from
[Magic & Lasers](https://magicandlasers.com) that runs both Anthropic and OpenAI — subscriptions
and API keys — side by side, in a real Mac app.*

---

# Part I — The mental model

Mechanician is built on **one simple model with two nouns**:

- A **Conversation** is one chat with Mechanician. It is the primary surface in every window,
  always.
- A **Workspace** is a place your conversations live. You always have **Home** — the default
  workspace, loose chats, nothing to set up. You create more workspaces when a body of work
  deserves its own place.

That's the entire vocabulary. There are no modes, no product lines, no third noun. One thing
varies: **a workspace may have a folder**. That single property — folder or no folder — is the
only fork in the app, and it's a property of the workspace, never a switch you flip.

## The ladder

The same two nouns carry you from casual chat to professional software development. Nothing about
the app changes shape as you climb — each rung just adds capability to the model you already know:

1. **Just chat.** Launch the app, type a question. You're in Home, the default workspace. A casual
   user can live here forever and never meet a container word.
2. **Organize.** When conversations start clustering around a subject — a trip, a research topic,
   a piece of writing — create a workspace for them. Its conversations, instructions, and results
   stay together, and it gets its own window.
3. **Create artifacts.** Ask for a page, a chart, a diagram, a document — it renders live in the
   workspace's preview pane and persists in the Artifacts library. A chat-only workspace with
   artifacts is a design studio; still no folder, no setup.
4. **Add a folder.** The moment a workspace gains a working folder, its conversations quietly gain
   a file browser, a live **Changes** panel that tracks what the agent touches (full git —
   branch, stage, commit, push — when the folder is a repository), and an instruction file
   (`CLAUDE.md` / `AGENTS.md`) the agent reads — and the embedded terminal and every agent turn
   now run in that folder. You can add the folder on day one or day fifty — a chat workspace
   becomes a working folder workspace whenever you're ready, losslessly.
5. **Professional development.** With a folder, you have the full agentic-coding workbench:
   permission approvals with per-tool "always allow" scoped to that folder, plan mode, mid-turn
   steering, multi-agent workflows, code review, builds. Coding isn't a mode you switched into —
   it's just what a conversation *does* when its workspace has a folder.

The test this model is held to: **a stranger can say in one sentence what a Conversation and a
Workspace are; the conversation is the primary surface in every window; and navigation is just
"pick a workspace."**

## The rules behind it

The design doctrine that keeps the model from eroding:

1. **No modes, ever.** Power arrives as capabilities the agent reaches for, not as sub-products
   you navigate between.
2. **Guard the noun set ruthlessly.** The user-facing set is closed: Conversation, Workspace, plus
   capability nouns (Artifact, Extension, Skill, Workflow, Scheduled Task).
3. **The conversation is always the primary surface.** Panels render beside, below, or pop out;
   nothing replaces the transcript.
4. **One name, one icon, no sub-brands.** The agent has capabilities, not product lines.
5. **Every new power attaches to the spine or hides behind a gate** — dark by default until
   earned. It never becomes a new destination in the chrome.

Windowing follows the nouns: **one workspace = one top-level native tab group.** Opening a workspace
focuses its existing group or creates the one; there are never two groups for the same workspace
(Home included). Conversations are native tabs within their workspace's group. Launch restores the
workspace you were in — the app never dumps you on an empty surface, and an upgrade never appears
to lose your conversations.

---

# Part II — Why two nouns

Mechanician fuses two ambitions that usually live in separate apps: **casual chat** and
**professional software development**. The risk in fusing them is that the app grows a taxonomy —
chats, projects, tasks, modes — and makes that taxonomy the user's problem. Mechanician's design
is a deliberate refusal of that outcome.

Two ideas do the work:

1. **Home** — the container-less front door. If you just want to ask a question, creating a
   "project" is heavyweight and meaningless. There has to be a place that requires no setup and no
   vocabulary. Home is that place, and it is itself a workspace — the default one — not a separate
   kind of thing.
2. **They're all just workspaces.** With Home in place, the third spine concept collapses away:
   your home workspace and your project workspaces are all simply *workspaces*. What used to be
   "Project" is retired from every user-facing surface, and the folder becomes the only fork.

The result is that "where does this conversation live?" always has a one-word answer: a workspace.
And "what mode am I in?" never comes up, because there are no modes — you talk, and the agent
reaches for the terminal, computer use, artifacts, or builds as the task demands. Power scales; the
surface stays the same shape.

---

# Part III — The "Mac-assed Mac app" standard

The phrase **"Mac-assed Mac app"** was coined by developer Collin Donnell and entered the written
record on March 19, 2020, when Brent Simmons
[credited him on inessential.com](https://inessential.com/2020/03/19/proxyman): it describes
"Mac apps that are unapologetically Mac apps. They're platform-specific and they're not trying to
wow us with all their custom not-Mac-like UI (which often isn't very accessible)." John Gruber
[popularized it the next day](https://daringfireball.net/linked/2020/03/20/mac-assed-mac-apps):
"I love this term. It's better and more clear than just saying 'native'."

The canon includes NetNewsWire, Proxyman, SoundSource, Fantastical, Sketch, Nova, and BBEdit.
Mechanician is built to that standard, and treats it as product, not polish:

- **An AppKit-owned shell.** AppKit owns the behavior-sensitive surfaces: the transcript is a native
  table view with native selectable text; the conversation list is a real `NSTableView` with
  Mail-style sections, swipe actions, and drag-to-Trash; and scrolling under streaming is governed
  by a single AppKit scroll authority. SwiftUI is reserved for content views inside that shell.
- **Real windows, menus, and tabs.** One workspace per window, conversations as native tabs, a
  full menu bar with state-reflecting items, a customizable unified toolbar, Space-safe tab
  behavior in full screen.
- **System integration a web view can't reach.** Native Quick Look (press Space in the file
  browser — arrow through the folder exactly like Finder), Spotlight indexing of conversations
  and artifacts, App Intents and Siri/Shortcuts phrases, a menu-bar status item, real
  notifications with click-through, AppleScript/JXA automation, and computer use.
- **Accessibility as a standing convention.** Every icon-only control in the app carries an
  explicit VoiceOver label — audited app-wide, not sprinkled.
- **Local-first trust.** API keys live in the macOS Keychain (written via stdin so they never
  touch a process list), and updates ship through Sparkle with an EdDSA-signed appcast on a
  Developer-ID-signed, notarized app. The SQLite `library.db` at the root of Mechanician's
  Application Support directory is the sole product authority for conversations, workspaces,
  artifacts, retained media references, and scheduled-task state. `projections.db` is a disposable
  search and summary projection that may lag that authority and may never lead it. Attachments stay
  in `conversation-media/`; see
  [docs/architecture/STORAGE-AND-PERSISTENCE.md](architecture/STORAGE-AND-PERSISTENCE.md) for the
  storage-admission, recovery, and rollback contracts.

---

# Part IV — The tour: every menu and control

## 1. The menu bar

### Mechanician (app menu)

| Item | Shortcut | What it does |
|---|---|---|
| **About Mechanician** | — | The About window: version, Magic & Lasers artwork, links to mechanician.ai and magicandlasers.com. |
| **Check for Updates…** | — | Runs the Sparkle update check (see [Updates](#13-software-updates)). |
| **Settings…** | ⌘, | Opens the Settings window (a real resizable window; see [Settings](#11-settings)). |
| **Hide / Hide Others / Quit** | ⌘H / ⌥⌘H / ⌘Q | Standard. Quit is guarded: if the agent is still working or prompts are queued, you're asked **"Quit Mechanician?"** first. |

### File

| Item | Shortcut | What it does |
|---|---|---|
| **New Conversation** | ⌘N | A fresh conversation in the current workspace, composer focused. |
| **New Tab** | ⌘T | A new native tab of this window, opening a fresh conversation in the same workspace. (When the terminal has keyboard focus, ⌘T makes a new *terminal* tab instead.) |
| **Open Workspace in New Window…** | ⇧⌘N | Opens **"Choose a Workspace"** — pick Home or any workspace; an already-open workspace focuses its window, an unopened one gets its window created. |
| **New Workspace…** | — | Opens the Workspaces launcher with a new-workspace draft ready to edit. |
| **Open Folder…** | ⌘O | Choose a folder to open as a workspace: if it already has one, that workspace's window is focused (or opened); otherwise the folder becomes a workspace with its own window. Never re-homes the current window. |
| **Open Recent** | — | The last ten folders; picking one focuses (or opens) that folder's workspace window. |
| **Open Folder in New Window…** | ⇧⌘O | The same focus-or-create behavior, available even with no workspace window active. |
| **Close** | ⌘W | Standard. |

### Edit

Standard system Edit menu (Undo, Cut/Copy/Paste, spelling, dictation, Emoji), plus:

| Item | Shortcut | What it does |
|---|---|---|
| **Find…** | ⌘F | Opens the find bar over the transcript. |
| **Find Next / Find Previous** | ⌘G / ⇧⌘G | Steps through matches. |
| **Use Selection for Find** | ⌘E | Uses the transcript selection as the query. |
| **Find Conversations…** | ⌥⌘F | Focuses the sidebar's conversation search field. |

### View

| Item | Shortcut | What it does |
|---|---|---|
| **Hide/Show Sidebar** | ⌃⌘S | Toggles the conversation sidebar (label reflects state). |
| **Hide/Show Inspector** | ⌥⌘I | Toggles the right inspector panel. |
| **Hide/Show Terminal** | ⌃⌘T | Toggles the terminal dock. |
| **Zoom In / Zoom Out / Actual Size** | ⌘= / ⌘- / ⌘0 | Chat & panel text size, 70%–160%. |

Plus the system tab-bar and full-screen items.

### Conversation

| Item | Shortcut | What it does |
|---|---|---|
| **Stop Generating** | ⌘. | Interrupts the running turn (enabled only while streaming). |
| **Copy Transcript** | — | The whole conversation as Markdown, onto the clipboard. |
| **Summarize (on-device)** | — | An Apple Intelligence on-device summary, appended to the transcript — private and free. |
| **Delete Conversation** | — | Deletes the current conversation (refuses while it has active work). |

### Workspace

| Item | Shortcut | What it does |
|---|---|---|
| **Home** | ⇧⌘H | Focuses the existing Home window, switches the current workspace window to Home when possible, or opens Home when no workspace window exists. |
| **Workspace Instructions…** | ⇧⌘I | Opens the shared instructions editor for the active Home or project workspace. |
| **Open/Add/Change Folder…** | — | Gives a folder-less workspace a folder or changes its existing folder through the guarded migration flow. |
| **New Workspace… / All Workspaces…** | — | Starts a new workspace or opens the complete workspace manager. |

### Window

Standard items plus one opener per utility window (each focuses the existing window if open):

| Item | Shortcut | Opens |
|---|---|---|
| **Providers** | ⌥⌘A | Provider accounts and managed configuration. |
| **Workspaces** | ⇧⌘P | The Workspaces launcher. |
| **Artifacts** | ⌥⌘Y | The global Artifacts library. |
| **Scheduled & Ambient Tasks** | ⌥⌘T | The Schedule window. |
| **Extensions** | ⌥⌘E | MCP servers, Claude plugins, and Codex plugins. |

### Help

**Mechanician Help** (⌘?) opens the in-app guides and a live **What it can do** inventory for the
current conversation. **Documentation on the Web…** opens
[mechanician.ai/help](https://mechanician.ai/help); **Send Feedback…** opens a new GitHub issue.

## 2. The workspace window

Each workspace window is: toolbar on top, sidebar (conversations) on the left, the transcript +
composer in the middle, an optional inspector on the right, and an optional terminal dock at the
bottom. The window's tabs are conversations; the window's identity is the workspace.

### The toolbar

- **Sidebar toggle** — glides with the split divider as the sidebar opens and closes.
- **The workspace switcher** — the prominent title control showing where you are (**Home** or the
  workspace name). Its dropdown is the fastest navigation in the app: **Home** (checkmarked when
  current), your workspaces (up to 12 — selecting one focuses its window, or switches this window
  in place if it isn't open anywhere), then **New Workspace…** and **All Workspaces…**.
- **Workspace actions** — the **⋯** beside the switcher opens **Workspace Instructions…**,
  **Open/Add/Change Folder…**, **Show Workspace Folder in Finder**, and **Workspace Details…** as
  applicable. The top-level **Workspace** menu exposes the same actions plus **New Workspace…** and
  **All Workspaces…**; **⇧⌘I** opens Workspace Instructions directly.
- **Browsers deck** — four app-wide controls on one surface: **Providers**, **Extensions**,
  **Artifacts**, and **Tasks**. A dot reports something actionable, active, or newly arrived; a
  right-click menu shows the underlying status and its relevant action without first opening the
  window. Toggle state stays in sync across every workspace window.
- **Terminal** and **Inspector** — this window's two panel controls, kept separate from the
  app-wide browsers.

The toolbar is customizable (right-click ▸ Customize Toolbar…); the conversation's name lives on
the window tab and sidebar, while the toolbar leads with the workspace.

### The sidebar

Header: **"Conversations"** with the current workspace's conversation count, a persistent filter
menu, a **⋯** actions menu, and the new-conversation button. The filter offers **All
Conversations**, **Unread**, and **Working**; Working includes both an in-flight root turn and
nonterminal delegated work. The chosen filter follows you across launches and workspace windows
without changing the underlying conversation library. The actions menu contains **Select All** —
which selects only the rows exposed by the current search and filter — and confirmed **Delete All
Conversations…**. Below the header, **Search** narrows this workspace's conversations by title or
any message text.

The list is scoped to the window's workspace and grouped Mail-style: **Pinned**, then **Today**,
**Yesterday**, **Previous 7 Days**, **Previous 30 Days**, **Older**. Each row shows title, relative
time, a one-line snippet, and a message count — plus, when it needs you, exactly one status dot
(orange = waiting on your answer or a provider connection, red = the last turn errored, accent =
unread result) and a live indicator (animated dots = running; ⏳ = waiting on a real-world
trigger and will auto-resume).

Interactions worth knowing:

- **Click** selects. Clicking a conversation that's *actively running* in another window jumps to
  that window instead — a live turn is never duplicated.
- **Click the selected row** (or press Return) to rename inline, Finder-style. **Double-click**
  opens the conversation in a new tab.
- **Swipe** right-to-left to delete, left-to-right to pin. Drag rows to the Dock's Trash to
  delete. Pinned rows can be drag-reordered within the Pinned band; drag an unpinned row into that
  band to pin it at the exact drop position, or drag a pinned row into the dated list to unpin it.
  An unpinned row always settles into the date section determined by its latest activity.
- **Drag to move.** Drag conversations (multi-select works) onto another workspace window's
  conversation list to move them there — the drop re-files them just like **Move to Workspace**,
  adopting the target's folder and bringing every artifact from those conversations. Dropping onto
  a Home window moves them back to Home — the one move the context menu doesn't offer.
- **Right-click** for the full menu: **Go to Conversation**, **Open in New Tab**, **Pin/Unpin** and
  **Mark as Read / Unread** (all multi-select aware), **Rename**, **Copy Transcript**,
  **Resume Now / Cancel Wait** (when a wait trigger is armed), **Move to Workspace ▸** (re-files
  the conversation, adopting the target's folder), and **Delete**.

Deleting one conversation is immediate; deleting several asks first; anything with active work
refuses until you stop it.

### The Workspaces launcher (⇧⌘P)

The one place to see and manage every workspace. **Home** and **Help** are compact, full-width
destination rows that use the same visual weight as the workspace cards below them. Both rows and
the favorites-first workspace grid share one scroll view, so Home and Help scroll out of the way
instead of consuming most of a short window. Each workspace card shows its icon (folder,
design-space, or chat), name, folder path or description, conversation count, and updated date.
Click to open — which always means *focus its one native tab group, or make this window become it*.

Every Home and workspace card has a visible **⋯** actions menu. **Workspace Instructions…** opens
the same in-app editor for Home, chat-only workspaces, and folder workspaces; Mechanician stores
that text in its own app data and adds it to future turns in every conversation in that workspace.
For a folder workspace, the editor separately shows the repository's root `CLAUDE.md` and
`AGENTS.md`; Mechanician creates or opens either file only when you explicitly choose that action.
Workspace cards also offer **Open**, **Edit…** (inline card editor: name, description, folder),
**Add Folder… / Change Folder…**, **Add to Favorites**, and **Remove Workspace** (removes the
workspace record; its conversations are not deleted).

**New Workspace** opens a draft card beside six starting points — Code workspace, Writing & docs,
Research, Design & prototypes, Data analysis, Planning — that prefill sensible names (never
overwriting anything you've typed). The two folder-based starters open the folder picker
directly.

**Folder changes are guarded.** Assigning a folder that another workspace already uses is
refused ("Folder already in use"); a busy workspace must stop first ("Workspace is busy"); and
when conversations are affected you're told exactly what will happen — *"N conversation(s) will
use the selected folder, and future turns will run there."* — before anything moves. The
operation is lossless: windows stay on their conversations, nothing is deleted.

## 3. The transcript

The conversation itself — native text you can select, search, and copy like any Mac document.

- **Assistant replies** render full Markdown: headings, lists, tables as real bordered grids,
  syntax-highlighted code blocks (One Dark/One Light adaptive). After a reply finishes, quiet
  icon buttons appear under it: **Copy** (raw markdown), **Retry** (last message only — rewinds
  and regenerates), and **Fork** (branches a new conversation — titled "*name* (fork)" — from
  that point, leaving the original untouched). Images generated by Codex appear directly in the
  transcript as primary content and remain visible after relaunch; they are not hidden behind a
  collapsed diagnostic row.
- **Your messages** sit right-aligned in accent bubbles, retaining named image and file previews
  that open through the normal Mac preview path. Right-click for **Copy** and **Edit & Resend**
  (loads the text and attachments back into the composer — it doesn't auto-send).
- **Tool activity is grouped**, not sprayed: consecutive tool calls collapse into one Activity
  card summarizing what happened ("3 writes · 2 reads · 1 command"), with failure counts when
  relevant. Expand it for per-action rows ("Ran `npm run build`", "Edited `RootView.swift`"…);
  click an action for full detail — commands, inputs, results, screenshots, and real colored
  diffs for edits.
- **Links are handled natively.** Web links open in your browser; file paths (including
  `path.swift:120` references) open inside Mechanician in a resizable file window that shows the
  full path. Right-click a local link—or use the file window's buttons—for **Preview in
  Mechanician**, **Open in Default App**, **Reveal in Finder**, or **Copy Path**. Binary and
  over-limit files hand off to their normal app.
- **The status strip** — a fixed lane between transcript and composer — shows the live turn:
  "Thinking…" (with a live glimpse of the model's reasoning), "Responding…", per-tool statuses
  ("Running command…", "Searching the web…"), subagent/workflow lines, and a ticking elapsed
  timer.
- **Scrolling follows correctly.** The view stays glued to the bottom while streaming; scroll up
  and it detaches so you can read; scroll back near the bottom and it re-attaches. Streaming
  never fights your gesture.
- **Cards appear inline where you're needed**: permission approvals (**Deny / Always allow /
  Allow once** — Return means Allow once), plan approval (**Keep planning / Approve & proceed**),
  agent questions (radio/checkbox options plus an "Other…" free-text field), expandable
  **Summarized earlier messages** markers with before/after token counts, and structured
  provider-failure cards with Retry/Reconnect actions. Claude markers show the exact continuity
  summary its SDK exposes (with an explicit notice if the safety limit clipped the end); Codex marks
  the boundary but keeps its summary text opaque. In both cases your full Mechanician transcript
  remains intact. (Provider-access requests appear as a card pinned just above the composer instead
  — see §8.)

## 4. The composer

Type, then **Return sends** (⇧Return for a newline). Everything else in the box:

- **Attachments**: paste images or arbitrary files, drag files anywhere onto the chat, or use the
  paperclip. Mechanician copies them into conversation-owned storage and shows named previews in
  both the composer and transcript, using Quick Look where available. Drag a preview within the
  composer to reorder it around text or other attachments; Undo/Redo works normally. Copying a
  mixed text-and-attachment selection into another conversation preserves its order and creates
  destination-owned copies. Pasting more than ~800 characters of text collapses into a
  "📄 Pasted text" pill so the box stays readable.
- **Artifact references**: drag an artifact from either Artifacts view into the composer. It stays
  an editable reference to the durable artifact — the agent receives its current source and can
  revise that same object. Dragging the artifact to Finder still exports a normal file.
- **@-paths**: type `@` to autocomplete files and folders (rooted at `/`, `~`, or the workspace
  folder), drilling into directories as you accept.
- **Slash commands**: type `/` for a completion popover of the conversation's skills; Tab/Return
  accepts. The full conversation-scoped list lives in the Inspector's Skills tab; Help ▸ What it
  can do also offers Insert and Run.
- **Dictation**: the mic button starts on-device-first voice input with a live waveform; ✓
  accepts, ✕ cancels. If the on-device recognizer is unavailable, Mechanician falls back to
  Apple's server-backed speech recognition. The mic can stay live across sends.
- **Drafts are per-conversation** and survive switching and relaunch.

**While a turn is running**, the composer becomes a steering console:

- **Stop** (⌘.) interrupts the turn.
- The send button gains a mode menu: **Guide current turn** (inject guidance into the *running*
  turn — delivered at the provider's next natural boundary, confirmed with a "Guidance delivered"
  chip, cancellable in flight while unconfirmed), **Send next** (queue behind the current turn),
  and **Stop and redirect** (⌥Return — interrupt and send this instead, with a **Resume** chip to
  re-run what was interrupted).
- **`/btw <message>`** is the interject shortcut: it interrupts, runs your aside, then
  automatically re-sends the original prompt.
- Undelivered guidance is never lost: if a steer can't be delivered, it moves — visibly — to the
  front of the queue. Queued prompts appear as editable rows above the composer and survive
  relaunch (a crash-restored queue waits for your **Resume queue** before running anything).
- When steering isn't possible (e.g. the OpenAI API lane), the composer says so and tells you the
  message will be sent next instead — no silent downgrades.

**The controls bar** under the composer:

- **Model picker** — one unified picker across both makers, grouped by the four account lanes
  (**Claude subscription**, **Anthropic API**, **Codex subscription**, **OpenAI API**), with
  search and capability filters. Each conversation keeps its own model. **⌘N** and **⌘T** in the
  same workspace inherit the exact provider and model from the conversation currently displayed;
  they use the saved workspace or app default only when there is no eligible same-workspace source.
  A model is never inherited across workspace boundaries. A disconnected lane shows its last-known
  models with an inline **Reconnect** — evidence, not a dead end.
- **Reasoning effort** — the levels the provider actually reports for the selected model (from
  Light/Low up to Max). Nothing is guessed.
- **Ultra** — a separate, capability-gated toggle for the top tier (Claude's Extra High +
  ultracode contract, or Codex `ultra`).
- **Plan** — read-only planning mode, with an explicit banner ("Plan mode · Read-only until you
  approve the plan") and honest "NEXT" badging when a change takes effect on the next turn.
- **Permissions** — the approval posture for this conversation, with provider-specific modes
  (e.g. Default / Accept edits / Bypass permissions for Claude; Workspace access / Auto-accept
  edits / Full access for Codex). Bypass/Full access carries an explicit warning.
- **Context meter** — live token usage against the model's window (turns orange past 75%, red
  past 90%), plus in/out token totals; a background-work chip ("N running") appears when other
  conversations or ambient tasks are working.

## 5. The inspector

The right-hand panel (⌥⌘I) is one configurable tool area with several possible tabs. A
folder-backed workspace starts with Files, Changes, Artifacts, Agents, and Skills. Home and other
folderless workspaces start with Artifacts, Agents, and Skills because Files and Changes require a
working folder. A fresh dedicated Help workspace starts with the inspector closed; when opened, its
only inspector tab is the signed product reader. Use the sliders button at the right edge of the tab
bar to choose which eligible tabs an ordinary workspace shows.

### Files

A Finder-grade browser of the working folder: real document icons, sortable Name / Date Modified /
Size columns, breadcrumb navigation, drag-and-drop in/out/within (moves inside, copies in/out),
inline rename (Return), and a preview pane below (images, PDF, HTML, rendered Markdown,
syntax-highlighted source). **Space triggers native Quick Look**, and ←/→ arrows walk the folder
exactly like Finder. Right-click gets you **Ask your agent about this** (drops a prompt about the
file into the composer), **Watch This File/Folder…** (creates a standing watch task), Quick Look,
Open, Reveal in Finder, Copy / Copy Path, Rename, and Move to Trash.

### Changes

The panel that answers "what has actually changed here, and who did it?", progressively:

- In a **git repository**: branch name with ahead/behind counts and a **Push** button;
  **UNCOMMITTED CHANGES** with staged/unstaged sections, per-file status codes, one-click
  stage/unstage, and a click-to-view diff pane; a commit bar ("Commit N file(s)") when files are
  staged. Files this conversation touched carry a **"Touched here"** badge. On Codex conversations
  with native review, a **Review** button has Codex review the uncommitted changes.
- In a **plain folder**: an honest **"Not under version control"** card and a list of observed reads
  and edits, explicitly *"not commits."*

**WORK RECORD** is the part that crosses conversations. A checkout is usually shared by many of
them, so the panel groups work by the conversation that did it: **Current Conversation** for this
one, and **Other Conversations** for the ones exactly linked to the same repository. Opening one of
those does not navigate away from where you are.

Every file in a work record says how Mechanician knows about it, because the three ways are not
equally strong:

- a successful **file tool** named the path directly;
- a **Git observation** saw the change for that conversation's recorded checkout;
- or it was **observed while a tool ran** and the attribution is unverified, which the panel says
  in those words rather than quietly rounding up to authorship.

A file the agent only read stays marked as read. Any entry opens to its evidence: the exact
transcript entry behind it, before and after digests, and the captured patch when there is one. A
capture too large to keep whole is bounded and says so. Files already in history read "Committed in
*abc123*".

What the panel refuses to do is as deliberate as what it shows. **A clean worktree does not prove
that conversation work reached the target branch**, and Mechanician will not infer intent,
authorship, or inclusion from one. An agent's own account of what it changed is labelled an agent
claim rather than Git evidence. A conversation with nothing captured says it has no work record
instead of appearing to have done nothing.

The panel refreshes itself: a quiet 2-second poll while visible, plus event-driven refreshes on
turn completion, file-mutating tools, and app focus, so the badge is right even when the panel was
closed while the terminal or the agent changed things.

### Artifacts

The current conversation's outputs, re-rendering live as the agent revises them: HTML and SVG in a
script-free web view, CSV as a native table, Markdown rendered natively, and Mermaid as a diagram.
Mermaid is laid out once with the pinned bundled renderer in a throwaway offscreen web view, then
sanitized and frozen to SVG. The visible preview still runs with `script-src 'none'`; agent-authored
content never executes there. A diagram that fails to render falls back to escaped source with the
renderer error. A dropdown switches between artifacts; **Open in a window** pops the artifact into
its own resizable window that keeps tracking revisions. Drag an artifact to the composer to revise
the same durable object, or to Finder to export a normal file.
Its context menu offers Favorite, Rename, Open in Default App, Share, Save to File, rendered
**Save as PDF** for HTML, Copy Source, Reveal in Finder, Delete, and **Move to Workspace** with
Home, existing, and new-workspace destinations. Moving changes where an artifact is organized
without severing its conversation provenance. The global Artifacts window adds native
multiple/range selection and bulk Favorite, Move, and Delete. When the agent produces an artifact
while the inspector is closed, the inspector opens itself on this tab.

### Agents

The conversation-scoped home for delegated work. The **This conversation** strip summarizes the
active turn — or the latest completed one — across the root and every delegate: current state,
active-agent count, whole-turn tool mix, elapsed time, provider-reported token totals, and current
root context.

Standalone subagents and multi-agent workflow runs appear as a parent/child tree grouped **Active /
Didn’t finish / Completed**. When observed, a running card shows the current step, optional target,
and time in that step. Available token and tool counts, child model, and call-count-based tool mix
appear without guessing missing values; compact rows fit a larger fleet on screen. **Possibly
stalled** means the step is unusually long relative to that agent's own completed steps, not that
the app has declared it stuck. Selecting an agent opens the available Status, Model, Task, Current
step, Tool mix, Tool timeline, Result, and Error fields, with a Copy action. Running standalone
agents can be stopped individually; a workflow's Stop ends the whole workflow.

Modern Claude keeps the root response cycle open while its authoritative background-task signal
says user-visible delegated work is still active, preserving that turn's tool context through the
root's response to completion. If another route still terminates with delegates outstanding — for
example Codex, a legacy Claude runtime without that signal, or a missing provider event —
Mechanician adds a durable transcript warning instead of implying those agents contributed to the
finished reply. The Agents tab continues to show the outstanding work, but its later tool calls may
be refused; ask again in a turn that stays open until they finish.

The hideable, resizable **Activity** pane follows the active turn by default (the latest turn when
nothing is running), while its turn menu opens retained history by date, provider, and model:

- **Trace** puts the root and reported delegate activity on one time axis: model work, tool calls,
  waits, native compaction, provider-visible history reduction, terminal marks, user guidance, and
  token volume. A history-reduction marker reports omitted/shortened message counts without
  pretending that the provider authored a compaction summary. Zoom, **Fit**, **1×**, and the Root +
  agents / Root only filter change the view without changing the data. A delegate can still have a
  card without a durable activity lane when its provider did not emit those records.
- **Path** underlines the chain the timeline calculates from temporal overlap as the elapsed-time
  path; it is not a dependency graph or merely the longest-running agent.
- **Usage** plots provider-reported token activity for all agents or one lane. When the provider
  supplies a breakdown, it separates new input, generated output, and the cached portion of input.
  A total-only report remains in **Processed** and the blue activity track, but that blue amount is
  not evidence of measured new input. Root context uses the reported window and shows remaining
  headroom when the provider supplies one; otherwise it scales to the observed peak. Compaction
  boundaries remain marked either way.
- In **Trace**, hover for a crosshair and readout; click to pin it. Left/right moves span by span,
  up/down changes lanes, ⌥←/⌥→ scrubs more finely, and Escape clears the inspection. VoiceOver gets
  the same lane, span, event, token-volume, and context structure.

### Skills

Every skill available to this conversation, grouped by the plugin that supplied it. Selecting a
skill arms it for the next message: a removable pill appears above the composer, and the message is
sent as that skill's command. Groups are collapsed by default and summarize what they contain;
searching expands them. Claude Code commands that only configure its terminal UI are hidden by
default because Mechanician has no such UI, but can still be shown or typed directly.

### Help

The inspector can also host a global record reader. **Help** searches the signed, build-matched
product guide, including article topics,
claim-level answers, history when requested, and tracked evidence. A Help window with no restored
layout begins with the inspector closed; once opened, the reader uses a document-friendly width.
Restored panel state and later choices in that window win instead of being changed on every focus.
In the dedicated Help workspace,
**Start tour** runs a native, step-by-step spotlight tour of that reader. More importantly, you can
ask the Help agent to **show me** a supported Mechanician feature, and most of those answers happen
in the app rather than in Help. Ask for the Changes, Agents, Artifacts, Skills, or Files panel, or
for the model, reasoning effort, and permission controls, and the guide runs in your own
conversation window: the window you asked from when that is an ordinary workspace, otherwise the
frontmost one that is. A guide can reveal a tab you
have hidden for as long as it runs, and puts it away again at the end unless the workspace already
showed it. Files and Changes still need a working folder, so those two are unavailable from Home
and the guide says so rather than opening an empty panel. The guide waits for Back, Next, Done, or
Exit and never sends a message, guesses coordinates, or runs arbitrary automation.

You can also just ask for the app to be operated rather than shown. **Open the Extensions window**,
**show me the Agents tab**, **put the cursor in the message box**, **start a new conversation**,
**switch this conversation to a different model or reasoning effort** — the agent does it, and the
result names what changed. It works from an ordinary conversation and from Ask Mechanician. What it
cannot do is the point: there is no way for it to change permission mode, connect or disconnect an
account, send a message, or delete anything, so operating the app never widens what it may do next.
It also does nothing while the conversation is in Plan mode.

Turning a configured connection on or off is the one thing it asks about first. **Turn on the GitHub
connection** puts up a card that says what is true now and what would become true, and nothing
changes until you press it — because that setting belongs to every conversation, not just the one
you are in. Declining is recorded as your decision, and the agent is told plainly either way. Reviewed **Try workflow** actions are the separate unsent handoff to a
standard conversation for demonstrations that really need tools. The record tab can be added to
another workspace through the tab settings, and pressing the active Help tab again returns its
reader to the root.

## 6. The terminal

A real terminal (SwiftTerm) docked under the chat — with tabs, inline rename, live light/dark
theming, and ⌘+/- font scaling. ⌘T opens another terminal tab while the terminal has focus, and
shells keep their scrollback when you switch tabs. The shell opens in the conversation's working
directory — the workspace folder when there is one, your home folder in Home and chat-only
workspaces — exactly matching where the agent itself runs.

## 7. The utility windows

Four app-wide utility windows are reachable from the toolbar and Window menu:

- **Providers (⌥⌘A)** — connect, reconnect, disconnect, and choose the default among Claude
  subscription, Anthropic API, Codex subscription, OpenAI API, and any managed provider routes.
  It is also where signed enterprise configuration is imported, reviewed, updated, replaced, or
  removed.
- **Artifacts (⌥⌘Y)** — the durable library of every artifact across all conversations and
  ambient runs: search, type filters, favorites, rename, source editing with conflict detection
  ("This artifact changed while you were editing"), drag-in import, drag-out export or chat
  reference, a consistent Share/Save/Open/Copy/Reveal context menu, and **Open Folder** to jump to
  the workspace that made it. You can also create artifacts by hand.
- **Scheduled & Ambient Tasks (⌥⌘T)** — the Schedule window: standing instructions that run
  unattended. Tasks trigger on a schedule (every N minutes, daily, once), on file/folder changes,
  or on new mail; results land as conversations, notifications, and auto-updating artifacts. A
  calendar shows planned occurrences and actual run history; a health pill shows the scheduler's
  heartbeat; **"Run when closed"** installs a background launch agent so tasks keep running after
  you quit (opt-in, off by default). While the app is open, an enabled task with a connected lane
  runs from a scheduler the app starts itself, so "Run when closed" is about surviving quit, not
  about turning scheduling on. Unattended runs are **read-only by default, not trust-all**: the
  editor's **Access** picker offers **"Read-only workspace access"** (the default) and a **Trust
  all** option labelled "full Mac access", and the read-only caption reads *"Can read the
  workspace and create artifacts, but cannot edit files, run shell commands, or control other
  apps."* Choosing Trust all replaces that
  with a warning: *"Full access runs without prompts. Use only workspaces, triggers, and
  instructions you trust."* Keep Mail triggers and file or folder triggers that another process or
  person can write **read-only** unless you have independently secured that input boundary. Their
  contents are untrusted input; Trust all would let that input drive full-Mac actions without a
  prompt. Scheduled runs need a metered provider route: an API-key lane in the standard app, or an
  eligible managed Vertex route. Subscription lanes cannot run unattended.
- **Extensions (⌥⌘E)** — three provider-aware destinations:
  - **MCP Servers** has Browse, Configured, and Add Server tabs. Browse loads the vendor-curated
    Microsoft Azure and GitHub registries by default, groups cards by the registry that supplied
    them, and filters by remote, local, or first-party entries. Configured separates remote and
    local servers, shows live authentication/tool status and provenance, and scopes credentials to
    the selected provider lane. Add Server accepts a remote HTTP endpoint or exact local launch
    command, which Mechanician shows and confirms before recording or starting it. npm servers use
    the bundled runtime; others may need the named runtime such as `uvx` or Docker. MCP works on
    both Claude and Codex; Claude-owned claude.ai connectors remain visible on Claude lanes.
  - **Claude Plugins** makes each marketplace a tab, with search plus category/component filters.
    Details name the skills, commands, agents, hooks, and MCP servers a plugin contains and report
    any always-on context cost. Add either a native Claude marketplace or an HTTPS plugin archive
    registry; installed plugins can be disabled, updated, or uninstalled.
  - **Codex Plugins** exposes OpenAI's remote catalog and local marketplaces with search, category
    filters, publisher/service details, install, and removal. Plugins that require the ChatGPT
    app's private browser or Chrome integration are deliberately not offered.

The former standalone Mac Automation and Skills windows are gone. Saved automations are listed in
Help ▸ What it can do, where they accurately read as capabilities the agent already has; skills
live beside the active conversation in the Inspector and in that same Help inventory.

## 8. Approvals, questions, and trust

- **Permission cards** appear in the transcript when the agent needs approval: what it wants
  ("Allow file changes?", "Allow this command?"), the exact command or file, and **Deny / Always
  allow / Allow once**. "Always allow" is scoped narrowly — per provider *and* per workspace
  folder — so approving a tool in one repo never silently approves it anywhere else. Destructive
  saved capabilities are never remembered; they re-confirm every time.
- **Writes outside the workspace remain contained.** Claude's **Bypass permissions** mode suppresses
  ordinary tool approval prompts, but it does not remove the workspace write boundary. If a path
  the agent requests resolves outside the current workspace — including after following a symlink
  — Mechanician asks before writing in every permission mode, including Bypass. The permission
  card names the requested path, the resolved target when it differs, and the current workspace.
  It also says that **Always allow** covers everything in the resolved target's containing folder,
  because a containment grant is remembered for that folder rather than only that file.
- **Plan cards** show the agent's plan as markdown with **Keep planning / Approve & proceed** —
  approving also exits plan mode so the next turn can act.
- **Question cards** render the agent's multiple-choice questions natively (with an "Other…"
  free-text option).
- **Extension questions** let an MCP server pause mid-turn for information it could not know in
  advance. Mechanician names the server first, then renders its confirmation, typed form, choices,
  or full HTTPS URL. **Deny / Not Now** is always available, required fields must be complete before
  Send, and an unanswered request times out rather than wedging the provider lane.
- **Provider-access cards** appear when work needs a provider family you haven't connected: the
  request's reason, the preserved prompts that will replay once connected, and one button per
  eligible route. Model output can only ever request a provider *family* — choosing subscription
  vs. API key is always yours, on this card.
- **Wait mode**: when work depends on a real external event, the agent arms a **WaitFor** trigger
  instead of pretending to wait. The conversation shows ⏳ ("Waiting *trigger* — I'll resume
  automatically") with **Resume now** and cancel controls, and resumes itself when the event
  fires.

## 9. The Mac integration layer

In a standard conversation, Mac automation tools are available only when that exact conversation,
provider route, and accepted turn report them. Help ▸ **What it can do** shows that route-owned
inventory rather than the last provider lane to speak. While a turn is active, its captured
permission mode and tool surface remain authoritative even if the toolbar already shows a different
choice marked **NEXT**; after the turn completes, its last-observed inventory remains eligible only
while the current picker still matches. A standard agent can also consult
`RecommendMechanicianWorkflow`: it matches the user's goal to reviewed, signed demonstrations and
labels each one **Ready to try here**, **Switch out of Plan**, **Not available in this
conversation**, or **Not verified yet**. A **Try workflow** draft binds this check to its exact
signed demonstration; the agent stops if the id differs or the label is not ready. That label is
advice, not an approval or proof that a live app, Shortcut, capability, or macOS permission exists.
An external action may still request confirmation, app approval, or macOS permission in any mode.

- **Menu-bar extra** — the bowler hat in your menu bar (on by default; Settings ▸ General): your
  scheduled tasks with **Run Now** / **Enabled** / next-run info, **Pause All Tasks / Resume All
  Tasks**, openers for Scheduled & Ambient Tasks, Artifacts, and Extensions, **New Conversation**,
  and Quit. The agent stays reachable with no window open.
- **Shortcuts / Siri / Spotlight** — seven App Intents ship ready to use: **Ask Mechanician**,
  **New Conversation**, **Open Conversation**, **Open Artifact**, **Run a Scheduled Task**,
  **Schedule a One-Time Task**, and **Watch a File or Folder** — with spoken phrases ("Ask
  Mechanician to …"). Conversations and artifacts are indexed in Spotlight (semantically, on
  macOS 15+), and a Spotlight hit opens the right window directly. Tasks created by the two
  scheduling intents are pinned to the read-only unattended profile (`permissionMode: "dontAsk"`
  in `MechanicianIntents.swift`); raising one to Trust all takes a deliberate edit in the Schedule
  window.
- **Notifications** — fired only when you're not actively watching that conversation (even in
  another Mechanician tab): turn finished, error, approval needed, plan ready, question asked,
  provider access needed, MCP session expired (click lands in Extensions), workflow finished,
  and ambient-run results (click lands in the Schedule window). One master toggle in Settings ▸
  General.

## 10. Accounts and providers

The **Providers** window (⌥⌘A) manages the four independent built-in lanes — **Claude
subscription** (your Claude Code login), **Anthropic API** (Keychain key), **Codex subscription**
(your ChatGPT login, app-scoped), and **OpenAI API** (Keychain key). Connect any or all; each row
shows live status, **Connect / Reconnect / Disconnect** (or **Add Key… / Replace Key… / Remove
Key**), and **Make Default** for new conversations. Sign-ins are real in-app OAuth flows;
disconnecting Claude never destroys your global Claude Code login (it's an app-local opt-out).
Account changes never retarget existing conversations — the per-conversation model picker does
that.

Providers can also import a signed `.mechanician-profile` into the standard app. A verified
enterprise profile can add managed Claude routes on Google Vertex AI or AWS Bedrock, plus managed
extension catalogs. A Bedrock route names an AWS region and may select one of your existing AWS
profiles; the Claude engine resolves the ordinary AWS credential chain (including AWS SSO or an
instance role), and Mechanician neither stores AWS access keys nor places them in the route
configuration. Open a downloaded profile directly, or choose **Import Configuration** in Providers;
Mechanician verifies the signature and shows what it will add before **Install and Relaunch** makes
it active. A profile may check its organization-owned feed automatically or only when you choose
**Check for Updates**. In manual mode, opening Mechanician does not contact the profile publisher.
Removing a profile takes effect after a restart.

There is no separate first-run sign-in screen. When a conversation's lane has no usable credential,
an account card appears above the composer, **"<Lane> needs a connection"**, with the reason and a
single action: **Connect** for subscription lanes (in-app OAuth) or **Choose Connection…**, which
opens the Providers window (⌥⌘A). Connect there and the conversation resumes.

Lanes run turns **concurrently** — a long Claude turn in one conversation doesn't block a Codex
turn in another, and you can hand work between them (including cross-provider delegation inside
workflows).

## 11. Settings

Six panes (⌘,):

| Pane | What's in it |
|---|---|
| **General** | Apple Intelligence status (on-device titling/summaries), the notifications toggle, and the menu-bar extra toggle. |
| **Appearance** | Theme (System/Light/Dark) and text size (also ⌘+/⌘-/⌘0). |
| **Permissions** | The default permission mode per provider, the remembered per-workspace "always allow" list (each removable), and Computer Use grants (Screen Recording, Accessibility) with deep links to System Settings. |
| **Extensions** | A launcher for the Extensions window, with configured-item counts. |
| **Updates** | Current version, signed-update channel, the chosen automatic/manual network mode, host-only update-network disclosure, and **Check Now…**. |
| **Advanced** | The 1M-token context window toggle (Anthropic lanes), read-only provider-capability diagnostics, **Export Redacted Lifecycle Diagnostics…** (a bounded Codex lifecycle trace with no prompts, responses, tool payloads, environment values, or credentials; enabled while a Codex runtime is connected, see [CODEX-LIFECYCLE-DIAGNOSTICS.md](CODEX-LIFECYCLE-DIAGNOSTICS.md)), and **Reset Window & Panel Sizes**. Dogfood builds add a Storage Status section that release builds do not show. |

## 12. Artifacts, previews, and Quick Look

Artifacts render in the inspector, pop out into live windows, and persist in the global library
(see §5 and §7). Dragging an artifact into a composer preserves its identity and current source so
the agent can revise it; dragging to Finder or choosing Save produces a normal file. File previews
render inline in the Files panel and in resizable, path-identified windows from transcript links;
native Quick Look or the file's default app covers everything else — Office/iWork documents, media,
archives — because a real Mac app can simply ask the system.

## 13. Software updates

Sparkle 2 with a fully native update panel: release notes, download progress, **Install and
Relaunch** — every build Developer-ID signed, notarized, stapled, and verified against an
EdDSA-signed appcast. On first run, an unmanaged installation chooses between **Manual Check Only**
(the default and recommended network-quiet option) and automatic update checks. Sparkle is not
started until that decision is recorded; manual
mode contacts the displayed app-update host only when the user chooses **Check Now…**. An MDM
update authority or managed automatic-check value takes precedence over the local choice. Settings
shows the update hostname and mode without displaying URL paths, query values, or credentials.

---

# Part V — Keyboard shortcuts

| Shortcut | Action |
|---|---|
| ⌘N | New Conversation |
| ⌘T | New Tab (new terminal tab when the terminal is focused) |
| ⇧⌘N | Open Workspace in New Window… |
| ⌘O / ⇧⌘O | Open Folder… / Open Folder in New Window… |
| ⇧⌘H | Home |
| ⇧⌘I | Workspace Instructions |
| ⌘F | Find in conversation |
| ⌘G / ⇧⌘G | Find Next / Find Previous |
| ⌘E | Use Selection for Find |
| ⌥⌘F | Find Conversations (sidebar search) |
| ⌘. | Stop Generating |
| ⌘, | Settings |
| ⌃⌘S | Hide/Show Sidebar |
| ⌥⌘I | Hide/Show Inspector |
| ⌃⌘T | Hide/Show Terminal |
| ⌘= / ⌘- / ⌘0 | Zoom In / Zoom Out / Actual Size |
| ⌥⌘A | Providers |
| ⇧⌘P | Workspaces |
| ⌥⌘Y | Artifacts |
| ⌥⌘T | Scheduled & Ambient Tasks |
| ⌥⌘E | Extensions |
| ⌘? | Mechanician Help |
| Return / ⇧Return | Send / newline |
| ⌥Return | Stop and redirect (interject) |
| Space | Quick Look (file browser) |
| ⌘W / ⌘M / ⌘H / ⌘Q | Close / Minimize / Hide / Quit (system) |

---

# Part VI — The ladder in practice

**Day one — just chat.** Open Mechanician, sign in to one provider, ask a question. You're in
Home. Conversations pile up loosely, searchable and pinned as needed. You have learned the entire
required mental model already: you talk; it answers.

**Week two — a place for a subject.** Trip planning has taken over four conversations. ⇧⌘P, New
Workspace, pick **Planning**. Configure nothing — drag the four conversations onto the new
workspace's window, or right-click ▸ Move to Workspace. That workspace now has its own window, its
own standing instructions if you want them ("We're going to Portugal in October; always answer in
this context"), and its own artifacts.

**Month two — a design studio.** In a "Design & prototypes" workspace, you ask for a dashboard
mockup. It renders in the preview pane, iterates live as you talk, pops out into its own window,
and lands in the Artifacts library. Still no folder. Still nothing to configure.

**Month three — the folder.** You want those mockups as real files in a repo. Toolbar ▸ **Add
Folder…** on the same workspace. The Files and Changes surfaces light up in place, and the
terminal and the agent now run in the folder — same workspace, same conversations, same tab group.
The Changes panel starts tracking what the agent touches; when the folder is a git repo, you
stage, commit, and push right there.

**Working professionally.** Open your project folder as a workspace (⌘O). The agent reads
`CLAUDE.md`, runs builds and tests behind the permission modes you've set, and you steer
mid-turn, queue follow-ups, review diffs in Changes, keep a terminal docked below, delegate to
workflows in the Agents tab, and let scheduled tasks watch the folder overnight. It is the same
app your first question ran in — two nouns, one fork, no modes.

---

*Mechanician is made by [Magic & Lasers](https://magicandlasers.com). See
[FEATURES.md](FEATURES.md) for a capability overview.*
