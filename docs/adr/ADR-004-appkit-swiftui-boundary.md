# ADR-004: The AppKit/SwiftUI boundary

- Status: Accepted
- Date: 2026-07-25
- Owners: Mechanician macOS application maintainers
- See also: [docs/architecture/APP-SHELL-AND-UI.md](../architecture/APP-SHELL-AND-UI.md), which
  carries the map of which surface lives on which side. This ADR carries only the rule.
- History: this ADR applies the first rule drawn from the Runtime Service revert of 2026-07-20,
  *state the user-visible outcome or do not start*. That episode is summarised in
  [docs/history/README.md](../history/README.md). The reverted ADRs themselves are in
  [docs/history/adr/](../history/adr/); do not implement from them.

## Context

Mechanician is a SwiftUI application with a substantial AppKit substrate. To see
how large it is right now, count the files that declare an `NSViewRepresentable`,
an `NSView`/`NSViewController` subclass, or an `NSWindowDelegate`/
`NSToolbarDelegate`:

```
grep -lE 'NSViewRepresentable|NSViewControllerRepresentable|: *NSView(Controller)?\b|NSWindowDelegate|NSToolbarDelegate' \
  app/Sources/Mechanician/*.swift
```

A fixed number is not recorded here, because the previous one rotted badly enough
to mislead. The pattern is what matters and it has been stable: a clear minority
of the source files, clustered in the window shell, the toolbar, the composer,
the transcript, the terminal, and the Agents panel, with the great majority of
content views untouched by AppKit.

That substrate was not planned up front. It accumulated one surface at a time,
each time because a specific defect could not be fixed from the SwiftUI side.

Because it grew by accretion, the question "should we just move the whole app to
AppKit?" recurs, usually right after a UI bug. It has been asked and answered
ad hoc more than once. This ADR records the rule so the answer stops depending
on how recent the last bug was.

The pressure is real in both directions. Native correctness *is* the product:
Mechanician is supposed to behave like a Mac app, and SwiftUI's bridged surfaces
have repeatedly failed to deliver that. But the Runtime Service refactor was
built and then reverted at a cost of tens of thousands of lines and a day of
emergency releases, and the first rule that came out of it was
**state the user-visible outcome or do not start**
([docs/history/README.md](../history/README.md)). A framework migration with no
user-visible outcome is exactly the shape that rule exists to stop.

### What the migrations that stuck have in common

Every surface that moved to AppKit shares a shape: **SwiftUI wrapped an AppKit
object and hid the control the fix required.**

| Surface | What SwiftUI hid | Where it lives now |
| --- | --- | --- |
| Transcript scrolling | Scroll authority during streaming reflow, with no way to tell user intent from content growth | `TranscriptPinController` and the wheel monitor in `ContentView.swift`; `NSScrollView` and row reuse in `AppKitTranscriptHost.swift` |
| Transcript row content | Synchronous layout and measurement at the real column width; streaming text settling through async intrinsic-size passes made the pinned transcript jump | `NativeAssistantCell.swift` (TextKit), `AppKitActivityGroupCell.swift`, `LayerBackedActivityViews.swift` (Core Animation) |
| Toolbar | Item identity, `NSTrackingSeparatorToolbarItem`, right-click routing | `WorkspaceToolbarController.swift` |
| Text input | `paste(_:)`, `importsGraphics`, first-responder and key-equivalent order | `ChatInput.swift` |
| Composer menus | A real `NSMenu` and its own event loop, and an assertable item list separate from the view | `ComposerAddMenu.swift`, `ComposerDeliveryMenu.swift` |
| Window, tab, and Space | Tab creation and full-screen Space association: `addTabbedWindow` throws unless both windows share a `tabbingIdentifier`, and joining a group in place is what keeps a new tab on the same Space | `MechanicianApp.swift`, `ProjectsLauncherView.swift` |
| Utility-window visibility | SwiftUI can retain a closed `Window` scene's native window, so "closed" and "never opened" are indistinguishable from the SwiftUI side; stable native identities make reopening deterministic | `UtilityWindowVisibility.swift` |
| Model-picker search field | Turning off inline predictions and the completion list, which SwiftUI's `TextField` does not expose | `PickerSearchField.swift` |
| Quick Look | Responder-chain participation, so `QLPreviewPanel` routes its data-source callbacks somewhere | `QuickLook.swift` |
| Terminal | The emulator is an AppKit view (SwiftTerm), plus key-equivalent interception while it holds focus | `TerminalPanelView.swift` |
| Agents panel | See the named exception below | `AppKitAgentsPanel.swift` |

This table is a set of examples, not a census. Run the `grep` above for the
current list, and see
[docs/architecture/APP-SHELL-AND-UI.md](../architecture/APP-SHELL-AND-UI.md) for
the full map.

Some of these needed a local `NSEvent` monitor to see events *before*
`sendEvent(_:)`. There are few of them and they are worth knowing individually:

```
grep -rn 'addLocalMonitorForEvents\|addGlobalMonitorForEvents' app/Sources/Mechanician/
```

At the time of writing that returns three, all local, none global: a
`.scrollWheel` monitor in `ContentView.swift` that establishes scroll authority
and is hit-tested to one scroll view; a `[.rightMouseDown, .leftMouseDown]`
monitor in `WorkspaceToolbarController.swift`, because `NSToolbar` swallows
right-clicks before any view sees them and control-click is the other way to ask
for a context menu; and a `[.leftMouseUp, .keyDown]` monitor in
`InspectorArtifactDragRetention` (`InspectorView.swift`), which watches for the
drop or the Escape key that ends a drag whose SwiftUI source view would otherwise
be torn down mid-drag by a spring-loaded tab switch. None of them is expressible
in SwiftUI at any level of effort. That is the signature to look for. A global
monitor would be a different and much heavier decision, and there are none.

`AppKitTranscriptHost.swift` already states the rule locally: *"AppKit owns
transcript scrolling, document geometry, and row reuse. SwiftUI is intentionally
limited to isolated row renderers."* This ADR generalizes that sentence.

### What is not evidence for migrating

Reviewing the defects fixed in this codebase over the sessions that produced the
list above, the causes were: a malformed JSON fixture, a synthesized `Decodable`
ignoring struct defaults, an error type that mapped to the wrong HTTP status, a
misread SDK contract on PKCE, and a helper compiled at runtime with a tool that
ships only with Xcode. **None of them were SwiftUI's fault**, and none would have
been prevented by AppKit.

One case is worth recording because it was nearly miscounted as evidence. A
SwiftUI `Toggle` appeared not to respond, and was briefly reported as an unverified
control. It responded correctly to `AXUIElementPerformAction(_, kAXPressAction)`:
the preference flipped and the child process started. The click had been aimed at
the centre of the row's accessibility frame rather than the switch. **The defect
was in the verification method, not the control**. See *Verification* below.

The `NSRemoteView`/ViewBridge popover crash is a macOS 27 beta OS regression
(FB23642313). Migrating would not fix it.

## Decision

**AppKit owns the shell. SwiftUI owns the content inside it.**

AppKit is the default for:

- window, tab, and Space lifecycle;
- toolbars, and anything expressed as an `NSToolbarItem`;
- scroll views, document geometry, and row reuse in the transcript;
- text input and anything that depends on first-responder or key-equivalent
  ordering;
- any behaviour that requires observing events before `sendEvent(_:)`.

SwiftUI is the default for everything else: panel content, lists and status
rows, forms, settings, pickers, inline cards. New content-level UI is written in
SwiftUI without needing to justify it.

### The test for which side a surface belongs on

> Does its correctness depend on an AppKit behaviour that SwiftUI wraps and does
> not expose (event ordering, first responder, scroll authority, item identity,
> or view reuse)?

Yes → AppKit. No → SwiftUI. "It would be cleaner," "it feels more native," and
"we're already using AppKit nearby" are not yes.

### Named exception: Agents inspector panel

The **Agents inspector panel**, including its agent list, detail surface, and
Agent Activity visualization, is approved as a narrow exception to the
content-level SwiftUI default. Its former SwiftUI implementation materialized a
large view graph with nodes for every agent card, trace span, and usage bucket.
Pointer inspection updates and the one-hertz live clock invalidated that graph
even when most of the panel had not changed. Keeping a SwiftUI shell around a
native chart would also have left the live card list on that same invalidation
path, so the exception covers the complete visible panel rather than only its
plot.

The trace-construction hot path was optimised first, and it is no longer the
dominant known cost. Reproduce that measurement with:

```
(cd app && MECHANICIAN_RUN_PERF_TESTS=1 swift test --arch arm64 --filter AgentVisualizationPerformanceTests)
```

It is opt-in for a reason: absolute timings vary too much across machines to be
a correctness gate. Note what it does and does not cover. It measures pure trace
calculation at the persisted ledger limit
(`maximumPersistedAgentActivityRecords` in `AgentActivityTimeline.swift`), not
SwiftUI diffing, layout, or drawing. So it does **not** quantify the performance
of the native panel, and no end-to-end speedup claim for this migration should be
made without a rendering benchmark, which does not exist yet.

The ownership boundary for this exception is explicit:

- One lifecycle-only `NSViewRepresentable` remains in the SwiftUI parent to
  mount and update the native surface.
- AppKit owns the entire visible Agents panel: layout, list and detail
  presentation, rendering, interaction, timer invalidation, scrolling, and
  accessibility.
- The representable is an integration seam, not a mixed rendering layer; it
  must not rebuild the panel from SwiftUI subviews.

This is not a general finding that AppKit is faster than SwiftUI, nor permission
to migrate other content panels. It is a named response to this panel's measured
workload and invalidation pattern.

### Non-goal

**Wholesale migration of existing SwiftUI content to AppKit is explicitly not
planned and should not be started.** It would be a large diff with no
user-visible outcome, against the standing rule recorded in
[docs/history/README.md](../history/README.md).

### When to revisit

Migrate a **specific named surface** when it has produced repeated,
user-facing defects traceable to the framework, not to our own logic. Record
the defects in the migration's commit message, so the next reader can weigh the
evidence rather than the mood. Absent that, the boundary holds.

## Verification

**Drive UI through accessibility actions, not screen coordinates.**
`AXUIElementPerformAction` with `kAXPressAction` invokes the control the same way
assistive technology does. Coordinate clicks depend on hit-testing a target
inside a possibly larger accessibility frame, and a miss is indistinguishable
from a broken control, which is precisely the false negative recorded above.

This has a useful corollary: **a control that cannot be driven through its
accessibility action is an accessibility defect**, and finding one is a real
result rather than a testing inconvenience. This composes with the standing rule
that every icon-only control carries an explicit `.accessibilityLabel`.

Prefer a testable seam over a framework argument. Split the decision out of the
view and the framework stops mattering to the test. `ComposerDeliveryMenu.swift`
does this: `ComposerDeliveryMenuModel.items(canGuide:selected:)` returns the item
list as data, so `ComposerDeliveryMenuTests.swift` asserts which options exist,
which is ticked, and where the separator falls, without opening an `NSMenu`.

## Consequences

- The question stops being re-litigated per bug; there is a written test to apply.
- Two idioms coexist permanently. That is accepted, not a defect to resolve.
- Each `NSViewRepresentable` is a seam that must be maintained by hand.
  `updateNSView` has to stay idempotent, and `dismantleNSView` has to actually
  tear down observers. This is the standing cost of the boundary.
- Contributors need to know both frameworks. That cost is bounded because the
  substrate is locatable: the `grep` above finds it mechanically, and
  [docs/architecture/APP-SHELL-AND-UI.md](../architecture/APP-SHELL-AND-UI.md)
  describes what each part is for.
- Some SwiftUI surfaces will keep minor rough edges that an AppKit rewrite would
  smooth. Accepted deliberately: the rewrite costs more than the edge.
