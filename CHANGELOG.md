# Changelog

All notable user-facing changes are recorded here. Per-release notes are also shipped to users
through the in-app updater (see `docs/release-notes/`). This project uses
[Keep a Changelog](https://keepachangelog.com) conventions and
[Semantic Versioning](https://semver.org).

## [Unreleased]

## 0.26.52 - 2026-09-08

### Added

- A dedicated Help workspace answers from a signed, build-matched product guide, presents reviewed
  walkthroughs in working conversations, and recommends exact-route workflows. Outside Plan it can
  also perform a closed set of requested interface operations.
- Conversation lists now include All, Unread, and Working filters, scoped selection and reliable
  bulk actions. New tabs inherit the active same-workspace conversation's provider and model.
- Artifacts have a native browser, while Changes records repository work across conversations.
- Managed deployments can enforce provider, permission, scheduling, extension, and update policy
  through forced MDM preferences. Stable releases include a signed, notarized enterprise PKG.

### Changed

- The workspace gallery now scrolls Home, Help, and named workspaces as one compact surface.
- The experimental personal Memory wiki, learned skills, and Memrank have been removed after
  testing showed that automatic retrieval was not reliable. Existing Memory workspaces become
  ordinary, renameable workspaces.
- Unmanaged installations now make an explicit first-launch choice between Manual Check Only and
  Automatic Update Checks. Manual is the network-quiet default, and managed policy can enforce the
  choice.

### Fixed
- Long conversations hold their place more reliably, retain Copy, Retry, and Fork after reload,
  and keep the composer responsive while background work is active.
- Claude keeps a workflow's permission context until its background agents finish. OpenAI scheduled
  runs now answer unattended permission and question requests using the correct protocol and retain
  inline and file-backed artifacts.
- Conversation switching and file previews stay responsive, large tool results are stored
  compressed, and only bounded excerpts enter the disposable search index.
- The repository-work warning no longer gets stuck after a provider fails before producing an
  assistant reply.
- Deleting a conversation with media no longer disables daily backups, and live conversations are
  checkpointed before abrupt app exits.
- Provider capacity, service, model-refresh, and Vertex reauthentication failures recover or
  explain themselves more clearly. Codex-generated images now appear in the transcript.
- Write-containment permission cards now explain why they can still appear with Claude's Bypass
  permissions. When a requested path resolves outside the workspace, the card names the requested
  path, resolved target and workspace boundary, and says which containing folder **Always allow**
  will cover.
- Plan-mode conversations no longer advertise or execute bounded app operations. The
  daemon and app now both reject stale or forged `OperateMechanician` calls while Plan is active.
- Agents can run the tools you have installed again. A Mechanician launched from Finder or by an
  update inherited a bare system PATH, so Homebrew and anything else on your own PATH was invisible
  to an agent's shell — `npm`, `gh` and `python3` came back as missing, and because the app bundle
  also carried a folder named `npm`, the shell reported that one as "permission denied". Agents
  read that as a blocked command and said so, whatever the permission mode. Mechanician now asks
  your login shell for its PATH.
- A turn waiting on a permission request no longer reports itself as stalled. If you left a
  permission card unanswered for a few minutes, Mechanician warned that the turn appeared stalled
  and offered to stop and recover it — which would have abandoned the turn it was asking you
  about. Nothing was wrong: the agent was waiting for you. The warning now appears only when the
  provider itself has gone quiet, and resumes watching as soon as you answer.
- Scheduled and background tasks now run with the same PATH as everything else. The scheduler is
  started by macOS rather than by the app, so it inherited an even barer environment than a window
  did — neither your own tools nor the runtime Mechanician ships — and an unattended agent reported
  ordinary commands as missing. It now resolves its PATH each time it starts, so editing a login
  file takes effect on the next run.
- The Node runtime Mechanician bundles no longer replaces yours. It was placed ahead of your own
  tools, so every command an agent ran used the app's pinned Node instead of the one your project
  expects. It is now a fallback, used only when you have none, and it ships a working `npm`
  alongside `npx` so a Mac without Node still runs npm-based connectors.
- Pin, Unpin, Mark Read, and Mark Unread now apply reliably to every selected conversation,
  including rows whose full transcripts are not currently loaded.
- Writing to `/tmp` no longer asks for approval. Mechanician always meant to let agents scratch in
  the system temp directory without being asked, but on macOS it only recognised the per-user one
  (`$TMPDIR`), so `/tmp` was treated as a write outside the workspace and prompted even with Bypass
  permissions set.
- Bypass permissions now survives reopening a conversation. Claude Code was launched in the mode
  but was never told the mode should stay available, so resuming a conversation quietly returned it
  to asking for approval while the picker still read Bypass permissions.
- Pinned conversations can now be reordered by dropping anywhere on another row instead of aiming
  for a narrow insertion line, and dragging them into the dated list unpins them reliably.
- MCP connections now acknowledge Connect or Sign In immediately, then distinguish preparing the
  secure request, opening sign-in, and waiting for the browser instead of leaving the clicked
  control looking unresponsive.
- Claude compaction summaries now start collapsed and cannot inherit an expanded disclosure state
  from another transcript row or conversation.
- When Google Vertex requires sign-in again, Mechanician now shows the reconnect state without
  inventing an invisible running turn. Reconnecting resumes the preserved prompt once and leaves
  the composer ready for the next message; restarting the app is no longer part of recovery.
- Mechanician corrects the permissions on its own support folder everywhere it checks them,
  including the two backup copies the 0.25.3 fix did not reach. A folder owned by another account
  is still refused, and the message now names the path and the permissions it found instead of
  restating the rule.

## 0.25.3 - 2026-08-06

### Fixed
- One more place a folder permission could stop Mechanician from starting. The same rule 0.24.2
  fixed was written in three places and only two were corrected; the third runs at the very end of
  the one-time library update. It now corrects the folder instead of refusing.

## 0.25.2 - 2026-08-06

### Added
- Settings, under Advanced, breaks the wait for your conversation at launch into the work it is
  made of rather than reporting one number.

### Fixed
- The one-time library update no longer stops on a shared attachment. Copying a conversation that
  contains an image leaves both conversations pointing at the same image file, which the update
  treated as a reason to refuse. One copied conversation was enough to hold up the whole library on
  every attempt. The image stays where it is, both conversations still show it, and the update
  continues. The same problem also prevented that conversation from saving after a successful
  update.
- When the update cannot finish, the message names what stopped it instead of restating the rule it
  was checking.

## 0.25.1 - 2026-08-06

### Fixed
- A conversation could stop saving and keep failing. A message that appeared and was withdrawn at
  the wrong moment, such as a streamed reply replaced by a final one, blocked every later save of
  that conversation until you restarted. Nothing was lost, because the save was refused rather than
  half-written.
- Siri, Shortcuts, and Spotlight see your whole library again. They were still reading the copy
  your library was migrated from, so anything created since the update could not be picked or found
  and anything deleted still turned up. Spotlight also no longer empties its list of artifacts when
  it cannot read the source.
- Settings can list conversations Mechanician could not read again, and restoring one sticks across
  relaunch. The exact original file is still kept, and you can still reveal or save a copy of it.
- A scheduled task runs in the right folder with the right instructions. It was reading workspace
  settings as they stood before the update, so an edited workspace ran with its old folder, a new
  one ran from your home folder, and a deleted one still ran.
- The space the update promised back is released. The check for a verified backup looked in the
  wrong place and always failed. Mechanician now reports what it released and how much came back.
  It releases only the rollback copy; the files your library was migrated from stay, because a
  conversation Mechanician could not read has its only remaining copy among them.
- Errors say what happened to your work rather than repeating the storage engine's own words, with
  the technical detail sent to the log. The same pass covered dictation, connection settings, and
  Keychain messages.

## 0.25.0 - 2026-08-06

### Changed
- Your library moves to a database. The first launch after this update runs a one-time migration,
  shows its progress, and reopens by itself. It writes a full backup and a rollback copy before
  changing anything, so it needs roughly twice the size of your attachments in free space; if there
  is not enough room it says so and does nothing. Your previous library is kept untouched for a
  week, after which Mechanician moves the leftovers to the Trash.
- A conversation Mechanician cannot read is carried across rather than left behind. Its exact file
  is preserved alongside the library with a note recording what it was and what went wrong.

### Added
- Settings, under Advanced, reports how long the last few launches took and where the time went.

### Fixed
- Opening the app is about twice as quick. On a 96-conversation library the sidebar became usable
  in 1.2 seconds instead of 2.5, and the conversation appeared in 2.9 seconds instead of 4.1. Most
  of that came from launch reading every finished subagent and workflow in the library, 104 MB of
  it, to answer one question about which conversations still had work running.
- A server that cannot use browser sign-in says so and offers a token, instead of failing with a
  Try Again button that could never succeed. Tools appear right after you connect a server rather
  than only sometimes. Reauthorizing while a message is already running says it cannot reach that
  turn, instead of showing Connected with no tools available.
- Choosing a workspace acts on the window you opened the gallery from rather than whichever window
  was last in front. It no longer pulls focus across Spaces or leaves two windows on one workspace.
- The Agents panel section for failed work is called "Didn't finish" and shows the agents that
  actually failed. One failed child used to bring its whole tree along.
- Check for Updates is always available, including when Mechanician cannot open your library, so a
  build that will not start can take the update that fixes it.
- The message shown when a conversation's history could not be measured says what happened to your
  conversation rather than describing the machinery.

## 0.24.2 - 2026-08-06

### Fixed
- Mechanician opens again. A bug in 0.24.1 could stop it opening at all: at startup it checks that
  its library folder is private to you, and a folder with the ordinary permissions macOS gives a new
  folder failed that check, showing "Storage Recovery Required" with no way forward except quitting.
  Mechanician now makes the folder private and carries on. Your library is untouched, and nothing
  about how it is stored changed.

## 0.24.1 - 2026-08-05

### Fixed
- Managed Vertex reasoning levels recover after transient account-checking and catalog failures.
  Route-validated cached levels survive launch, stranded refreshes resume when the account becomes
  usable, signed deployment profiles can supply verified levels without a discovery race, and the
  Effort popover now reports a failed refresh with Retry instead of loading forever.

## 0.24.0 - 2026-08-04

### Added
- Full-text conversation search covers tool output, and the sidebar paints from a cached summary
  while the rest of the library loads in the background.
- The File menu can export a conversation as a `.convrec` snapshot and inspect one. Inspection is
  read-only: importing a record or resuming work from it is not supported yet.

### Changed
- Workspace moves, exports, and other multi-conversation work load what they need in the
  background instead of blocking the interface.
- Your prompt is saved before the provider receives it. A crash during turn startup restores it
  visibly and paused rather than losing it or silently resending it.

### Fixed
- Managed Claude deployments now load provider-reported reasoning levels when the Effort control
  opens. Signed model declarations previously made the catalog look ready before its capability
  metadata was fetched, leaving the menu empty and the visible saved preference unapplied.
- Startup restores the exact saved Conversation and retains the first valid sidebar selection made
  before recovery completes instead of showing a blank Conversation or discarding clicks.
- Pin/Unpin, read state, and pinned-row ordering work again in the Conversation panel.
- Typing the first character no longer shifts or bounces the transcript.
- The Agents panel opens when a workflow or subagent first starts, and live workflow children
  appear once rather than as duplicate rows.
- Forked and replayed conversations say where they came from and what a replay cannot reproduce,
  instead of implying an exact continuation.
- Conversation and Workspace save failures stay visible and can be retried, and search is not
  updated until the save actually succeeds.

## 0.23.0 - 2026-08-02

### Added
- Local transcript file links now provide Mac-native choices: preview in a resizable Mechanician
  window with the full path, open in the default app, reveal in Finder, or copy the path. Source
  references resolve to their files, while binary and over-limit files hand off to their normal app.

### Fixed
- Find keeps the exact current words highlighted across long messages, streaming updates, offscreen
  rows, and row reuse.
- The conversation sidebar's rows, count, and search remain strictly scoped to Home or the current
  workspace. Conversation startup, restoration, forks, moves, and navigation retain that canonical
  workspace identity.

## 0.22.0 - 2026-08-01

### Added
- ⌘P prints the conversation you are reading. The title goes at the top, and the standard Mac
  header and footer carry the job name, the date, and "Page 2 of 12". The page is always light with
  black ink whatever appearance the app is in. What reaches the page is your messages and the
  replies: tool calls print as one compact line each, and anything the model withdrew never prints,
  the same rule that keeps it out of Copy Transcript. Images are not printed yet.

### Fixed
- Save as PDF no longer comes out dark. Exporting an artifact in Dark Mode produced light text on a
  dark background, a page of solid ink on paper. Exports are always light now, while the preview
  panels still follow the app.
- The agent activity chart stays inside its panel. Cards no longer overflow at wide or narrow
  inspector widths, the live edge follows the pixels that mean "now", and a short running turn no
  longer stretches to fill the viewport.

## 0.21.0 - 2026-08-01

### Added
- ⌘Z puts back anything Mechanician removed or moved, and never touches what an agent did. Moving
  a conversation or an artifact to another workspace, deleting a conversation, deleting every
  conversation, and deleting an artifact all come back. A whole multi-selection undoes as one step,
  so moving twenty conversations is one ⌘Z. Deleting still asks first. A restored conversation is
  exactly what you had, including its queued prompts still paused, so nothing is sent on your
  behalf. While you are typing, ⌘Z still undoes your typing.
- ⌘F searches the conversation you are reading, with a count of where you are ("3 of 17"). ⌘G and
  ⇧⌘G step through matches and ⌘E searches for the selection. A match inside a collapsed tool group
  opens it rather than being skipped. Searching your list of conversations moved to ⌥⌘F.
- Services. Select text in any app and use its Services menu to start a new conversation with that
  text, or add it to the conversation you already have open. The second leaves Mechanician in the
  background so you can clip several passages without being pulled out of Safari each time. In
  Finder, open the selected folders as workspaces or attach the selected files to a conversation.
- `mechanician://` links open a conversation, a workspace, or an artifact from a note, a script, or
  a Shortcut. Copy Link is on the Conversation menu, the sidebar, the artifact list, and the
  workspace cards.
- Nothing sent from outside ever sends on its own: text and files land in the composer and stop
  there for you to read before you press Return.
- Quitting and reopening restores the whole session, not one window. Every workspace window
  returns, tab groups come back whole and in order, and focus lands on the window and tab you were
  last in. A workspace deleted in the meantime is not reopened.

### Fixed
- Opening two conversations in quick succession no longer leaves one window blank.
- Revealing an artifact works on a cold launch and can no longer open a second Artifacts window.
- Text pasted from another app cannot smuggle in a file attachment you did not choose.
- Tool labels on the orange ray are legible again.
- Confirmation sheets no longer claim deleting cannot be undone, because now it can.

## 0.20.0 - 2026-08-01

### Added
- The composer's paperclip is now a `+` that opens an add panel: recent photos you can click straight
  into the message, a camera tile, a full photo browser in its own window with multi-select and
  per-photo progress, screen-area capture, and files. Option-clicking the `+` still opens the file
  picker directly. Recent photos are opt-in, so opening the panel never triggers a permission prompt,
  and choosing photos works even when the library is not readable.
- Take Photo uses the built-in camera or a nearby iPhone acting as a Continuity Camera.
- The message box now declares itself able to receive imported images, so macOS offers "Import from
  iPhone or iPad" in its context menu. That is also the only route to document scanning on macOS.

### Fixed
- Composer attachments can be dragged to a new position again, both images and file previews.
  `NSTextView`'s own gesture recognizers consume the press before `mouseDown` is entered, so the drag
  now arms from the drag itself.
- An attachment drag carries a preview macOS can encode. The previous placeholder had no
  representations, which logged an image-encoding error for every frame of the gesture.
- Selecting several photos attaches all of them. Exports written within the same second collided on
  one filename, and transcoding to PNG inflated photos past the composer's whole-batch import budget
  so everything after the first was silently dropped. Photos now transcode to JPEG only when their
  original format is one the provider cannot read.
- Tool span labels in Activity Trace take white ink wherever white is legible, instead of whichever
  ink scored marginally higher. Saturated blue labels were black at a 0.05 contrast margin and could
  not be read. The palette is unchanged.
- Moving conversations to another workspace moves every selected conversation rather than only the
  clicked row.
- A build without camera support says so instead of offering a Settings pane it can never appear in.

## 0.19.2 - 2026-07-31

### Fixed
- The live activity plot no longer holds stale bars while its ruler advances: agent lanes and the
  token graph repaint with the timeline instead of waiting for an unrelated rebuild, and a running
  turn's horizon only moves forward rather than jumping ahead and snapping back.
- Selecting a large source file under Conversation History in Changes shows its contents again
  instead of an empty read-only preview pane.
- Taking a suggested follow-up adds it to whatever is already typed, on its own line, and leaves the
  cursor in the composer ready to keep typing. It previously replaced the draft and moved focus out
  of the box.

### Changed
- A prepared provider process is now reused by any conversation needing the same setup, so opening a
  new conversation no longer restarts that preparation and its first message waits less. Typing also
  re-prepares a connection that lapsed while a conversation sat idle. Applies to Claude on a
  subscription, an API key, Vertex, and Bedrock, and to Codex.

## 0.19.1 - 2026-07-31

### Fixed
- Managed Vertex Claude connections no longer wait on an unsupported context control or rebuild an
  otherwise healthy provider session between turns. Supported Claude routes can also avoid the
  synchronous context preflight on confidently safe chained turns while retaining conservative
  compaction safeguards for uncertain and near-limit contexts.
- Activity Trace tool spans now use the same stable per-tool colors as the agent-card tool mix, and
  its key accurately shows and explains that palette to sighted and VoiceOver users.
- The live Usage token graph keeps completed activity anchored as a turn grows instead of sliding
  older bars backward; scale transitions merge buckets predictably two at a time.

## 0.19.0 - 2026-07-31

### Added
- Composer attachments are announced to VoiceOver in the same words the transcript uses, so an
  attached file, mail message, image, or artifact is identifiable while a message is being written.
- A file dragged out of the file browser can be dropped on the Trash, which previously refused it.
  Removal is recoverable.

### Fixed
- The Files tab now springs open when an artifact is held over it, so the artifact can be dropped
  into a chosen folder. The tab had never responded to a drag.
- Artifacts dragged to the Finder or another app arrive named `Badge.svg` rather than
  `Badge.svg.svg`.
- Renaming a conversation in Light Mode showed white text on a white background.
- The context meter's empty track was nearly as dark as its blue fill, so the reading was lost.
- Tool activity labels in the timeline are drawn in white on a deeper orange instead of black.
- Pressing Delete in the conversation list with nothing selected could act on the last right-clicked
  row; both delete keys now require a selection.

### Changed
- A private MCP registry is read by the general registry adapter and described entirely in managed
  configuration, so supporting an organization's own catalog no longer requires an app release.
  Registries already installed keep working and migrate themselves.

## 0.18.0 - 2026-07-31

### Added
- Messages dragged from Apple Mail are preserved as conversation-owned RFC 822 files, identified as
  Mail in the composer, expanded into bounded readable context for the agent, and available as
  collapsible transcript cards with sender, date, body, and Open Original actions.

### Fixed
- A conversation opened through its provider-recovery card now applies the explicitly chosen,
  verified account route without requiring a second model-picker step, while preserving its draft
  and history. Connect and Reconnect return focus to Mechanician after verification.
- Light Mode now keeps readable contrast across activity, extension, Help, badge, and status
  surfaces; selected conversations remain distinctly blue and token history no longer uses
  beige/gold fills.
- Activity timelines retain their right edge and lower token history, and the compact three-color
  spinner remains visible without a white backplate.
- At the minimum window width, the inspector yields space and conversation controls compact before
  the composer becomes unusable.

## 0.17.0 - 2026-07-30

### Added
- Artifact context menus can move one or many artifacts to Home, an existing workspace, or a newly
  created workspace; moving a conversation now brings all of its artifacts with it.
- HTML artifacts can be exported as rendered PDFs, including content below the preview viewport.
- The Artifacts library now supports Mac-style multiple/range selection and bulk Favorite, Move,
  and Delete; the inspector adds Favorite, Rename, and Delete parity.
- Files of any type are copied into conversation-owned storage and shown as named Quick Look-backed
  previews in the composer and transcript. Composer attachments can be dragged into a new authored
  position with undo/redo.
- Promised RFC 822 files are preserved as conversation-owned attachments with bounded readable
  context for the agent.

### Fixed
- Activity Trace now marks provider-visible history reduction separately from native compaction,
  including omitted/shortened message counts, and scrolling guidance flags no longer paint through
  the frozen lane-label gutter.
- Copying a mixed selection of text, images, and files between conversation composers now preserves
  its authored order and creates durable destination-owned attachment copies.
- Light, Dark, and System appearance changes now update every open window and custom AppKit layer
  together. Light Mode now has vivid brand-colored agent meters and timelines, high-contrast Git
  diffs and syntax, readable status colors, and a visible chromatic composer shimmer.
- Artifact exports are pruned at launch and clean quit, and long sessions keep their temporary
  export identity index bounded.
- Hovering an artifact over the Files tab spring-loads it without tearing down the active drag
  source.
- Rename, favorite, source edit, delete, and workspace assignment now converge across the durable
  artifact store, conversation snapshots, open previews, and live workspaces.

## 0.11.14 - 2026-07-23

### Added
- Artifact context menus in conversation and global artifact panels provide native sharing, saving,
  opening, copying, and Finder actions.

### Fixed
- The file preview's Quick Look fallback now uses Mechanician's current compact pill styling.

## 0.11.13 - 2026-07-23

### Fixed
- New workspace windows remain standalone on macOS Tahoe, even when another workspace is full
  screen; the explicit New Tab command still creates a native workspace tab.
- Claude's context meter now uses provider-reported window metadata and resolves catalog aliases
  such as `default` and `[1m]`, instead of incorrectly falling back to 200k.
- Finder drops activate the workspace, app/Dock drops reach the composer, and image attachments
  retain their visible preview.
- Vertex startup verification no longer lets malformed proxy responses terminate the provider
  runtime, and unexpected exits now retain their real exit status instead of appearing as generic
  network failures.
- Claude's required Ask control is eagerly mounted; stale sessions are invalidated so the next
  message recreates the provider dispatcher with durable transcript replay.

## 0.11.12 - 2026-07-23

### Fixed
- Workspace windows on macOS Tahoe no longer grow when the multiline composer grows.
- Vertex AI Claude keeps configured ADC accounts connected across transient verification failures,
  and the effort picker now loads its active workspace catalog without depending on the model picker.
- Fresh Claude turns prioritize the user's prompt over optional startup discovery, bound extension
  readiness to five seconds, and label that stage separately from model thinking.

## 0.9.5 - 2026-07-19

### Added
- A redacted Codex lifecycle diagnostics export in Advanced Settings, which you trigger yourself
  and which never contains prompts, output, tool arguments, environment values, or credentials.

### Fixed
- Codex turns now use one lifecycle reducer that knows which provider identity owns a turn, so a
  turn ends exactly once, stale results are rejected, and recovery is bounded.
- Quiet Codex work remains active after reconciliation, while approval and user-input waits are
  surfaced explicitly instead of looking stuck.

## 0.9.4 - 2026-07-18

### Fixed
- App launch no longer blocks while macOS performs first-execution validation of bundled Node or
  while launchd refreshes the background scheduler.
- Provider and ambient process launches are asynchronous and discard late results after a window
  closes, the app quits, or scheduler policy changes.
- The installed ambient daemon refreshes once per app build rather than on every launch.

## 0.9.3 - 2026-07-18

### Added
- A pinned, bundled Codex App Server and code-mode host make Codex subscriptions self-contained.

### Fixed
- Codex Ultra quiet turns reconcile against authoritative App Server state, recover missing
  completion notifications, and keep stop/restart lifecycle ownership generation-safe.

## 0.9.2 - 2026-07-18

### Added
- **Zero-install runtime.** Release builds now bundle a supported, checksum-verified Node 24 LTS
  runtime and prune platform-specific/development-only package files.
- **Built-in Git reads.** The Changes panel can show repository status and staged, unstaged,
  untracked, and binary diffs without Xcode or Apple Command Line Tools.

### Changed
- Release builds are Apple-Silicon-only and fail closed if the pinned Node runtime cannot be
  downloaded or verified.
- Git write actions remain disabled without Command Line Tools and now offer an explicit install
  or Xcode-license action while read-only diffs remain available.

## 0.9.1

### Fixed
- **Model-picker crash.** Worked around a macOS 26/27 ViewBridge window-ordering regression
  (Apple FB23642313) by disabling remote text-completion services on the picker's search field
  and stabilizing the conversation-controls toolbar.
- **Reliability.** Sidecar files (conversations, projects, extensions, tasks) are written
  atomically and undecodable files are quarantined instead of silently dropped; conversations are
  de-duplicated on load; sidebar ordering is stable across relaunch.
- **Security.** The `WaitFor` check command is gated like a shell tool; capability approvals are
  bound to script content; ambient inbox triggers fence untrusted email as data.
- **Performance and leaks.** Computer-use accessibility walks run off the main thread with a
  bounded timeout; closed workspace windows are reclaimed; large-file edit hashing is capped.
- **Misc.** Ambient daily schedules at midnight fire correctly; the OpenAI edit tool no longer
  mangles `$` patterns; restarting a terminal tab no longer kills its replacement.

## 0.9.0

- Conversation controls, workspace navigation, and portability refinements. (See
  `docs/release-notes/` and the in-app updater for the full per-release history.)

---

Older releases predate this changelog; their notes are distributed via the in-app updater.
