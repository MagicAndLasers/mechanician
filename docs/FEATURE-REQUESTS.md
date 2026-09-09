# Feature requests

> **Memory, Memrank and Connections were removed on 2026-09-02.** The requests below that ask
> for a memory wiki, learned skills, recall cards, semantic contexts or the Connections map are
> kept as a record of what was asked for, not as work that is still open. Nothing in the app
> answers them any more. `AGENTS.md` records why the subsystem was retired, under **Do not
> predict what an agent needs**; read it before proposing any of them again.

## 2026-08-31: Keep the live harness span synchronized with the trace timeline

The harness span in Agents Activity must use the same continuously advancing live clock and time
scale as every other open span. It must not appear to grow only in provider-event-driven spurts or
drift away from the ruler and neighboring spans. Preserve authoritative provider milestones while
making the displayed open tail smooth, truthful, and consistent across Claude and Codex.

## 2026-08-31: Legible per-turn duration trends

Make the Agents Activity duration trend interpretable without outside explanation. Show a labeled
time axis with useful units and a zero baseline, identify wall duration and time to first output
directly in the chart, give retained turns enough chronological context to distinguish them, and
show exact values for the selected turn. Missing provider measurements must read as not reported
rather than looking like plotted values. Preserve provider attribution, keyboard selection,
VoiceOver, bounded retained history, and truthful per-turn scaling.

## 2026-08-25: Persistent feedback state on recalled-memory cards

When a recalled-memory card has already received contextual feedback, show the current saved
decision on the card itself: Useful here, Not useful here, or No longer true. The selected state
must be immediately visible after a successful write, remain correct after reopening or
rerendering the card, distinguish relevance feedback from truth retirement, and preserve the exact
statement, conversation, workspace, subject, provider, accessibility, and failure behavior.

## 2026-08-25: Immediate, stable Connections rendering

Connections must retain its last complete, authority-fenced visualization while a newer map is
being prepared, then replace it atomically. It must never repeatedly disappear, flash through
partial context-only content, or make someone wait for a slow graph redraw before seeing their
saved relationship map. Context cards must have a bounded native layout in which the node-type
eyebrow, semantic-family title, four-turn window, and connection summary never overlap or obscure
one another at any supported size, zoom, or accessibility setting. Keep the complete learned map
and its graph geometry stable until an exact fresher receipt is ready, while clearly indicating a
refresh without showing stale authority as current.

## 2026-08-25: Profile-built Connections availability

After a successful Build profile or Refresh profile, Mechanician must precompute the disposable
Connections projection from the same current authority so a workspace, including one with no
previous warm cache such as Northwind, has an immediately available visualization. This preparation
must not create learned associations from ordinary activity, change Memrank scoring, or mutate
the library beyond the normal profile build. A workspace with no learned association evidence must
still show its truthful saved-activity visualization immediately, explain why no learned graph is
available, and rebuild only disposable derived state when necessary.

## 2026-08-24: Inspectable multi-turn semantic contexts

Connections must present each learned context as the semantic family it actually is, not as a
single representative prompt. Make the complete bounded user-turn window and the count of
independent matching windows immediately legible on the card and in its details, so a person can
distinguish a semantic family from one of its examples. Keep the underlying family, evidence
provenance, and learned context-to-statement relationships exact; do not manufacture a topic name
or imply that one prompt alone created the context.

## 2026-08-24: Workspace-level semantic context recurrence

Form Memrank contexts from repeated compatible multi-turn activity across a Workspace, not only
within one Conversation and an arbitrary fixed history segment. A semantic context should be one
reusable unit that can recur over time and across related Conversations, then be located near a new
query in semantic space to activate only its actual learned statement associations. Preserve exact
Workspace/Home, provider, subject, source, feedback, veto, dormancy, and authority fences; a
cross-Conversation family must retain each member window as provenance and never turn activity
similarity alone into learned statement support.

## 2026-08-24: Semantic-context topology in Connections

Connections must disclose the sparse semantic-similarity relationships between recurring context
families that the model already uses for semantic matching. These are not learned
context-to-statement associations: render and label them as a separate relation, preserve exact
Workspace/Home fences, and keep the graph legible by showing only defensible nearest similarities.
Their strength or similarity must never be mistaken for learned memory conductance, feedback, or
query influence. A selected context should make its similar contexts and their shared evidence
inspectable alongside its exact statement associations. Organize the map into stable semantic
neighborhoods: context families belong together through similarity, while statements are placed
with the neighborhoods that actually associate to them; a statement shared by several neighborhoods
must remain a visible bridge rather than being arbitrarily assigned to one.

## 2026-08-24: Coherent, meaningful Connections rendering

Connections must never render a staged or context-only graph that leaves people looking at generic
`Recurring context` boxes with no visible relationship to memory statements. Build and reveal one
coherent learned map, with a truthful loading state while that map is unavailable. A learned map
must make the participating pages, statements, and connection strengths legible; zero-edge saved
activity belongs in its explicitly non-learning activity timeline, not in the learned graph. The
surface must remain responsive and must not make people wait through a slow incremental render
before it explains anything useful.

## 2026-08-24: Graphical saved-activity fallback in Connections

When a selected Conversation has saved activity but no current recurring learned Memrank family,
Connections must retain a substantial native visualization instead of collapsing to static feedback
cards or an empty canvas. Render bounded chronological saved activity windows and their exact saved
feedback annotations as a clearly labeled activity timeline. The timeline must make plain that its
path represents time order only, is not a learned context-to-memory graph, has no connection
strength, and cannot affect scoring, retrieval, or feedback authority. Preserve the exact
Conversation/Workspace fence, keyboard navigation, VoiceOver, and the full-height Connections
canvas.

## 2026-08-24: Reliable Memory inspector access

Make the Memory tab in the inspector reliably select and display the embedded Memory record. A
visible Memory tab must never accept a click and leave the prior inspector content on screen or
silently revert selection. Preserve workspace-scoped tab preferences, accessibility, and the
single authoritative Memory surface.

## 2026-08-24: Refreshable memory profile builds

Once a memory profile exists, provide a clear Refresh profile action that rebuilds it from current
eligible authority without making people delete or recreate their profile. Explain that it updates
derived suggestions, preserve accepted memory and authority data until an explicit reviewed change,
prevent overlapping builds, and retain truthful progress, cancellation, failure, and accessibility
behavior.

## 2026-08-24: Compact icon feedback controls on recall cards

Replace the verbose recall-card actions `Useful here`, `Not useful here`, and `Mark no longer true`
with three compact, Mechanician-styled icon controls on one line: a checkmark, xmark, and
circle-with-slash. Render them as small rounded-rectangle toolbar controls with a restrained
hairline and no oversized enclosing tile—not circular/oval mini-pills. Preserve their full action
names as hover and VoiceOver labels, keep the truth-maintenance action semantically and visually
distinct from contextual feedback, and do not change any authority, feedback, or truth-retirement
behavior. A click must immediately show the chosen/pending state, then an unambiguous saved or
failed result; it must never wait for a graph rebuild before acknowledging the action.

## 2026-08-24: Inspectable provider compaction and context-window memory delivery

Keep Mechanician's complete canonical transcript while making provider compaction visible at the
exact point it occurs. Show an expandable inline boundary with trigger/token detail and the exact
provider-authored continuity summary when a supported provider exposes one; label opaque providers
honestly and never present a reconstructed synopsis as provider state. Make the result durable,
accessible, printable, searchable, and available in transcript exports. Automatically deliver each
exact wiki-memory revision only once within a retained provider context, make edits eligible again,
and start a new delivery window after successful compaction or a genuinely empty context rebuild.
Preserve that delivery window across a physical session/thread replacement when the exact retained
provider context is transferred into the replacement.
Preserve explicit recall, subagent isolation, fresh-session recovery, and equivalent Claude Agent
SDK and Codex behavior wherever their provider surfaces permit it. For Codex, recover the exact
provider-authored compacted context through a supported interface when possible, expose any
human-readable continuity summary with honest provenance, and preserve a provider-compatible
continuation artifact for rebuilding a replacement thread without depending on the hidden original
thread. Fall back to canonical transcript replay when that artifact is unavailable or incompatible.

## 2026-08-24: Provider-context screenshot elision after analysis

Delay provider compaction by retiring screenshot image payloads from the provider's active context
after they have been successfully analyzed, while retaining the original screenshots in
Mechanician's authoritative transcript. Replace each retired provider-context image with a durable,
attributable textual observation sufficient for continuity, and make the substitution inspectable
without implying that the original media was deleted. Preserve exact replay and recovery behavior,
allow the original image to be supplied again when later work genuinely needs pixels, and apply the
optimization only where the provider API can prove that the replacement actually changes its active
token budget.

## 2026-08-24: Direct, legible Connections navigation and semantic map

Make a selected Conversation scope in Connections directly reversible: people must be able to return
to the containing Workspace map without hunting for a second control or inferring a hidden state.
Replace the current two-step expansion path with one nearby, clearly named control that gives the
map a genuinely full-height canvas and restores the ordinary surface without losing scope, selection,
zoom, or accessibility. Recurring semantic-context nodes must have meaningful, authority-safe labels
and explain their independent evidence windows; generic labels such as `Recurring semantic context`
and truncated, unexplained examples are not an adequate visualization of the learned model. Keep
enduring activity contexts visibly distinct from evidence-only semantic families: a long
Conversation must not appear blank simply because its recalled evidence has not yet formed a
reinforcing family, and the map must say which kind of context a person is inspecting.

## 2026-08-23: Recurring semantic contexts in Memrank

Make the primary Connections map represent canonical, reusable semantic-context families rather
than one anchored activity episode per saved user message. A family must accumulate only compatible
repeated evidence episodes within exact Home/Workspace, Conversation, and subject fences; statement
visibility remains separately subject to the existing provider and privacy admission fences. Show
recurrence and member episodes without inventing aggregate connection strength. Retain every
anchored episode as the exact provenance, feedback, veto, dormancy, and conductance coordinate. The
family/prototype layer must be canonical, versioned, generation-fenced, and emitted by Memrank—not
inferred or clustered by UI code.

## 2026-08-23: Clearly actionable truth maintenance

Make the recall-card truth-maintenance control unmistakably look and read like an action. Replace
the label-like `No longer true` treatment with a visible Mechanician-styled button whose wording,
hover/focus states, and VoiceOver label make clear that it marks the displayed statement as no
longer true. Keep this separate from contextual relevance feedback and preserve the existing
authority compare-and-swap behavior.

## 2026-08-23: Height-first Connections workspace

Give the Connections visualization substantially more vertical room. The graph must not be confined
to a shallow inspector band: support a clear expanded/full-height presentation while preserving the
resizable graph/details split, usable narrow-window behavior, keyboard navigation, and the exact
authority-fenced map.

## 2026-08-23: Meaningful learned-context labels

Replace Connections’ fallback labels such as `Activity A` through `Activity AD` with concise,
authority-safe descriptions of each saved activity anchor. A person must be able to tell why two
contexts from the same Conversation are distinct without exposing hidden identifiers or collapsing
their exact learned edge fans. Keep a stable compact fallback only when fresh anchor text is not
admissible, and make the same meaningful label available in the graph, inspection pane, keyboard
navigation, and VoiceOver.

## 2026-08-23: Stable transcript viewport during late row measurement

Keep a reader's visible transcript anchor fixed when a large Conversation replaces estimated
offscreen row heights with exact measurements. Late native table-height corrections must not make
the transcript visibly jitter when the person is away from the bottom and is not actively
scrolling, while bottom-pinned streaming and deliberate scroll gestures retain their existing
behavior.

## 2026-08-23: Searchable Memrank scope picker

Replace Connections' flat Workspace and Conversation menus with searchable, keyboard-navigable
scope selection that remains practical as the library grows. Support filtering by fresh local
Workspace and Conversation names, preserve exact Home and named-Workspace identity, make the
containing Workspace clear for every Conversation result, and never turn missing or filtered
authority rows into a wildcard scope.

## 2026-08-23: Inspectable learned Memrank maps

Make large Workspace and Conversation Connections maps understandable rather than a wall of
repeated labels and truncated cards. Distinguish each exact anchored-turn context with fresh,
authority-safe display information; add a directly resizable native graph/detail split to learned
maps; and show the complete selected statement and exact learned-edge values without changing or
aggregating Memrank weights. Preserve deterministic layout, privacy and provider fences, keyboard
navigation, VoiceOver, and selection state across current-generation refreshes.

## 2026-08-23 — Persistent, immediate Memrank maps

Restore the last exact Workspace or Conversation Connections map immediately after relaunch instead
of opening on an empty transient decision. Reuse the generation-matched learned graph already stored
in `projections.db`, refresh it automatically when authority changes, and keep opening the Memory
workspace responsive by avoiding redundant indexing and repeated whole-library curation passes.

## 2026-08-23 — Workspace and Conversation Memrank maps

Make Connections a full-size, graph-first surface rather than a shallow inspector sample. Preserve
the exact latest-decision explanation, and add a current learned map for every exact Home or named
Workspace and every Conversation. Workspace and Conversation maps must use Memrank's canonical
context-to-statement edges and learned conductance without inventing query influence, historical
precision, weighted page relationships, or statement-to-statement topology. Keep fresh authority
joins, provider/privacy fences, deterministic navigation, keyboard access, and VoiceOver.

## 2026-08-23 — Resizable Memrank Connections panes

Make the graph and exact decision-detail panes in Connections directly resizable with a visible
native divider. Preserve useful minimum sizes, support pointer, keyboard, and VoiceOver adjustment,
and retain the chosen balance while the Connections surface remains open.

## 2026-08-23 — Professional Memrank Connections visualization

Turn Connections into a polished, native, graph-first explanation of the latest exact Memrank
decision. Make participating contexts, memory statements, page containment, learned connection
strength, query-specific influence, dormancy, and applied contextual vetoes visually distinct while
retaining the canonical numeric detail, deterministic layout, authority fences, keyboard access,
VoiceOver, and immediate stale-decision clearing.

## 2026-08-23 — Pi-inspired context sovereignty and bounded agent work

Apply the strongest parts of Pi's philosophy to Mechanician without importing its generic provider
model, terminal UI, session authority, or unsafe extension defaults. Make app-owned model context
attributable, inspectable, budgeted, and progressively disclosed; keep agent lifecycle and tool
results explicit; support review-gated self-extension and bounded research-to-implementation
handoffs; and preserve human review, provider-native behavior, AppKit ownership, SQLite authority,
and Mechanician's deliberately exhaustive provider lanes.

## 2026-08-23 — Engaging memory curation loop

Make curating recalled memories feel like shaping a living knowledge map: give each statement clear
identity and provenance, make useful/not-useful/no-longer-true decisions satisfying and immediately
visible, and surface small meaningful opportunities such as confirming an uncertain memory, resolving
a conflict, or connecting an orphaned statement. Progress should reflect improved clarity, coverage,
and relevance—not streaks, arbitrary points, or rewards for accepting claims—and every interaction
must preserve privacy, authority, reversibility, keyboard access, and VoiceOver.

## 2026-08-23 — Professional native Memory recall presentation

Polish the expanded “Recalled from memory” transcript card so it has a deliberate macOS visual
hierarchy rather than a stack of oversized pale boxes. Keep the reusable and interactive surface in
AppKit, make page/statement grouping and feedback actions immediately legible, and support narrow
transcripts, keyboard navigation, VoiceOver, cell reuse, and light/dark appearance.

## 2026-09-01: Trace-first Activity panel

Open the Activity panel on Trace for every new panel, workspace-window presentation, or reveal,
regardless of which Activity tab was last used. Preserve an explicit tab choice while the panel
remains visible, but never let Trends or Usage become the next presentation's implicit default.

## 2026-09-01: Informative, polished Activity trends

Turn the Activity Trends tab into a legible native observability surface with clear metric identity,
time and scope, readable values and units, useful grouping, and concise explanations of what each
chart or runtime instrument represents. Reduce truncation and undifferentiated tinted rows, establish
a stronger information hierarchy, retain exact values on inspection, and preserve narrow-layout,
keyboard, VoiceOver, light/dark appearance, and Claude/Codex parity.
