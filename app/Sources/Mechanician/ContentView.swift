
import SwiftUI
import AppKit
import UniformTypeIdentifiers

enum TranscriptGuidanceIconTone: Equatable {
    case statusTint
    /// The system label color remains legible in light, dark, increased-contrast, and custom-accent
    /// appearances. Use it for the filled interjection diamond instead of tinting that dense symbol
    /// with the same accent used by its translucent capsule.
    case adaptiveHighContrast
}

func transcriptGuidanceIconTone(
    for state: TranscriptEntry.GuidanceState,
    activelySending: Bool
) -> TranscriptGuidanceIconTone {
    state == .delivered && !activelySending ? .adaptiveHighContrast : .statusTint
}

/// Mutable inputs that change a guidance row's native AppKit presentation. The transcript host
/// reuses rows until their revision changes, so these must participate even after the row is no
/// longer the transcript tail (for example when a fast provider acknowledges guidance after it has
/// already emitted another row).
struct TranscriptGuidanceRenderState: Hashable {
    let state: String?
    let failureReason: String?
    let isPending: Bool
}

func transcriptGuidanceRenderState(
    for entry: TranscriptEntry,
    isPending: Bool
) -> TranscriptGuidanceRenderState {
    TranscriptGuidanceRenderState(
        state: entry.guidanceState?.rawValue,
        failureReason: entry.guidanceFailureReason,
        isPending: isPending)
}

/// Stable transcript ordering while the root and one or more guidance messages are all provisional.
/// The root must remain first; otherwise guidance typed during a slow `turn_started` handshake
/// appears above the message it is meant to steer.
func transcriptEntriesForRendering(
    durable: [TranscriptEntry],
    provisionalRoot: TranscriptEntry?,
    provisionalGuidance: [TranscriptEntry]
) -> [TranscriptEntry] {
    var rendered = durable
    if let provisionalRoot { rendered.append(provisionalRoot) }
    rendered.append(contentsOf: provisionalGuidance)
    return rendered
}

/// Non-transcript inputs that can change a projected row. Exact assistant appends reuse the cached
/// row array only while every one of these remains equal; any coalesced UI-state change therefore
/// falls back to the canonical projection instead of leaving a stale control, image, or Find mark.
private struct TranscriptProjectionInputs: Equatable {
    let conversationID: UUID?
    let previewRevision: UUID?
    let chatScale: CGFloat
    let isStreaming: Bool
    let cwd: String
    let find: AgentBridge.FindState
    let expandedTools: Set<UUID>
    let toolImageIDs: Set<UUID>
    let pendingGuidanceEntryIDs: Set<UUID>
    let provisionalRoot: TranscriptEntry?
    let provisionalGuidance: [TranscriptEntry]
}

/// The control bar keeps one live copy of every popover trigger. A hidden, non-interactive width
/// probe decides whether the activity/usage group belongs beside the controls or on a second line.
enum ControlBarTier: Equatable {
    case full
    case wrapped
    case compact

    var stacksRows: Bool { self != .full }
    var usesCompactControls: Bool { self == .compact }
}

enum ProviderWarningPresentation {
    static let iconSize: CGFloat = 16
    static let frameSize: CGFloat = 20
}

/// Width budget for the compact primary row at the supported 300-point chat minimum. Four
/// icon-only triggers (including their chevrons), three dividers, deck chrome, and the provider
/// warning remain comfortably inside this budget; titles, badges, and metrics move out of the row.
enum CompactControlBarContract {
    static let horizontalPadding: CGFloat = 12
    static let iconTriggerWidthBudget: CGFloat = 44
    static let maximumTriggerCount: CGFloat = 4
    static let deckDividerAndChromeBudget: CGFloat = 21
    static let primaryRowSpacing: CGFloat = 8

    static var requiredWidth: CGFloat {
        iconTriggerWidthBudget * maximumTriggerCount
            + deckDividerAndChromeBudget
            + ProviderWarningPresentation.frameSize
            + primaryRowSpacing
            + horizontalPadding * 2
    }
}

private struct ControlBarTierKey: PreferenceKey {
    static let defaultValue: ControlBarTier = .wrapped
    static func reduce(value: inout ControlBarTier, nextValue: () -> ControlBarTier) {
        value = nextValue()
    }
}

struct ContentView: View {
    @EnvironmentObject private var bridge: AgentBridge
    @ObservedObject private var ambient = AmbientStore.shared
    /// Tracked descendants of this window's daemons. Observed here so the background-work chip
    /// updates when one starts or exits, not only when the Schedule panel is open.
    @ObservedObject private var backgroundProcesses = BackgroundProcessStore.shared
    @ObservedObject private var projectStore = ProjectStore.shared
    @ObservedObject private var accounts = ProviderAccountStore.shared
    /// Ultra availability is published by the process-wide catalog owner, not by the window's
    /// bridge. Keep observing that owner so the deck updates when authoritative metadata arrives;
    /// each popover now owns independent presentation state in ConversationControlPickers.
    @ObservedObject private var catalogs = ModelCatalogStore.shared
    /// Observed so a signed guide's semantic anchors attach and detach with its presentation. The
    /// router hands back a registry only for the exact window the guide was admitted into.
    @ObservedObject private var guidanceRouter = MechanicianGuidanceRouter.shared
    @Environment(\.openWindow) private var openWindow
    @AppStorage("uiTypeStep") private var typeStep = 0
    /// The composer draft, deliberately NOT observed by ContentView: a keystroke must invalidate
    /// only ComposerCard (which observes it) — never the transcript, whose visible rows re-parse
    /// JSON/markdown per evaluation. Other writers (suggestions, drops, inject, Edit & Resend)
    /// mutate the object; the card re-renders, nothing else does. This was the typing lag.
    @State private var draft = ComposerDraft()
    /// The conversation whose text is currently in `draft` — lets a switch restore the right
    /// per-conversation draft (see AgentBridge.setDraft/draft(for:)).
    @State private var draftedID: UUID?
    @State private var dropTargeted = false
    // Voice input: the composer text as it was before dictation started, so the streamed
    // transcript can be spliced in after it.
    @StateObject private var dictation = SpeechDictation()
    // Inline editing of a queued prompt (nil = none being edited).
    @State private var editingQueueIndex: Int?
    @State private var editingQueueText = ""
    @FocusState private var queueEditFocused: Bool
    @FocusState private var findFieldFocused: Bool
    /// THE scroll authority (see TranscriptPinController): auto-follow is pinning, done entirely
    /// in AppKit off document-growth notifications; stickiness flips only on genuine user input
    /// over this scroll view. SwiftUI never scrolls during streaming — the overshoot-then-clamp
    /// fight between scrollTo (estimated lazy heights) and the AppKit settle was the bounce.
    @State private var pin = TranscriptPinController()
    /// Presentation-only and window-local. Canonical `TranscriptEntry` values remain on the bridge;
    /// this cache merely keeps the already-projected historical rows out of the streaming hot path.
    @State private var transcriptProjectionCache =
        AppKitTranscriptProjectionCache<TranscriptProjectionInputs>()
    /// One-time post-migration notice: (conversationCount, projectCount) while pending, so the
    /// cwd→Projects partition reads as intentional organization rather than lost history.
    @State private var migrationNotice: (conv: Int, proj: Int)?
    /// The completed post-soak reclaim worth reporting, loaded once rather than decoded per body
    /// pass. Visibility is gated on `reclaimNoticeDismissedAt` rather than on clearing this, because
    /// `ContentView` exists once per workspace window: dismissing in one window has to settle the
    /// banner in every window, and `@AppStorage` republishes to all of them. The migration notice
    /// above predates that rule and still paints on in whatever windows were already open.
    @State private var reclaimNotice: StorageRollbackReclaimCoordinator.Receipt?
    @AppStorage(StorageRollbackReclaimNotice.dismissedAtKey)
    private var reclaimNoticeDismissedAt: Double = 0
    /// SwiftUI gives the sidebar's first text field the initial responder before the native
    /// composer finishes attaching to its window. Request composer focus once, on the next main
    /// run-loop pass, after both surfaces exist. Later explicit focus changes (⌘F, Terminal, etc.)
    /// remain untouched.
    /// Which width tier of the conversation-controls bar fits, per the hidden probe — see
    /// `conversationControlsBar`.
    @State private var controlBarTier: ControlBarTier = .wrapped
    /// A model-provider change is committed only after its native picker window has ordered off.
    /// Keep sibling popover triggers inert during that short interval so another control cannot
    /// become the reflow target while the provider publication lands.
    @State private var isModelSelectionTransitioning = false

    // Crash-safe chat zoom: scale transcript fonts (no view transforms) via ⌘+/-.
    private var chatScale: CGFloat { uiScale(typeStep) }

    /// The one guide registry this window may register into. Nil whenever no signed guide is
    /// presenting here, which is what keeps the anchors out of every ordinary render.
    private var guideRegistry: GuidedHelpTargetRegistry? {
        guidanceRouter.registry(for: bridge)
    }

    var body: some View {
        VStack(spacing: 0) {
            if let n = migrationNotice { migrationBanner(n) }
            if let r = reclaimNotice,
               !StorageRollbackReclaimNotice.isDismissed(r, dismissedAt: reclaimNoticeDismissedAt) {
                reclaimBanner(r)
            }
            if let preview = bridge.conversationTranscriptPreview {
                conversationSwitchPreview(preview)
            } else {
                transcript
                liveStatusStrip
                // `mayPresentSuggestedPrompt` covers the delegated-work case for the same reason
                // `transcriptStatusVisible` does: a root turn can finish while its workflow keeps
                // going, and offering the next prompt beside a live "Running command…" strip is
                // the app contradicting itself.
                if let suggestion = bridge.presentedSuggestedPromptRecord,
                   bridge.mayPresentSuggestedPrompt,
                   !suggestion.text.isEmpty {
                    suggestionBar(suggestion)
                }
                if effectivePlanMode { planModeBanner }
                composer
                conversationControlsBar
                if bridge.showTerminal {
                    ResizeHandle(size: terminalHeightBinding, axis: .vertical, range: 120...400)
                    TerminalPanelView()
                        .frame(height: resolvedTerminalHeight)
                }
            }
        }
        .background(Color.nBg)
        .onAppear(perform: loadMigrationNotice)
        .onAppear { reclaimNotice = StorageRollbackReclaimNotice.pending() }
        // The reclaim finishes on a background queue well after launch, so a window that is already
        // open would otherwise not hear about it until the next one.
        .onReceive(NotificationCenter.default.publisher(for: StorageRollbackReclaimNotice.didReclaim)) { _ in
            reclaimNotice = StorageRollbackReclaimNotice.pending()
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.nAccent, style: StrokeStyle(lineWidth: 2, dash: [8]))
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            handleChatDrop(urls)
        } isTargeted: { dropTargeted = $0 }
        .onChange(of: bridge.currentID) { _, newID in
            // Per-conversation drafts: persistCurrent already saved the OUTGOING conversation's draft
            // (via bridge.liveDraft) before currentID changed, so here we just load the incoming one —
            // each conversation keeps its own queued-up, unsent message.
            draft.text = bridge.draft(for: newID)
            draft.conversationID = newID
            bridge.composerDidLoadDraft(draft.text, for: newID)
            draft.resetHeight(fontSize: 13 * chatScale)
            draftedID = newID
        }
        .onAppear {
            // Bind the composer to this window's current conversation, and let persistCurrent capture
            // the live unsent text on navigate-away / teardown (the draft object stays view-isolated).
            //
            // `draft` and `bridge` are reached through `self`, which this closure captures strongly.
            // Bind them to locals first so the `[weak …]` lists below unambiguously weaken *these
            // objects* rather than a property lookup through a strongly-held view. The distinction
            // matters: the bridge stores these closures for its own lifetime, and the weak capture
            // is exactly what keeps the draft view-isolated instead of outliving its window.
            let draft = draft
            let bridge = bridge
            draftedID = bridge.currentID
            draft.text = bridge.draft(for: bridge.currentID)
            draft.conversationID = bridge.currentID
            bridge.liveDraft = { [weak draft] in draft?.text ?? "" }
            bridge.liveDraftConversationID = { [weak draft] in draft?.conversationID }
            bridge.replaceLiveDraft = { [weak draft, weak bridge] conversationID, text in
                guard let draft,
                      draft.conversationID == conversationID,
                      bridge?.currentID == conversationID else { return false }
                draft.text = text
                return true
            }
            bridge.composerDidLoadDraft(draft.text, for: bridge.currentID)
        }
    }

    @ViewBuilder
    private func conversationSwitchPreview(_ preview: ConversationTranscriptPreview) -> some View {
        if preview.entries?.isEmpty == false {
            VStack(spacing: 0) {
                transcriptScroll
                    .disabled(true)
                    .allowsHitTesting(false)
                HStack(spacing: 8) {
                    OrbitingDots(diameter: 14)
                    Text(verbatim: ConversationOpeningPresentation.accessibilityLabel)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(Color.nSurface)
                .overlay(Divider(), alignment: .top)
            }
            .accessibilityElement(children: .contain)
        } else {
            ConversationOpeningView()
        }
    }

    private var displayedTranscriptEntries: [TranscriptEntry] {
        bridge.conversationTranscriptPreview?.entries ?? bridge.entries
    }

    private var displayedTranscriptConversationID: UUID? {
        bridge.conversationTranscriptPreview?.conversationID ?? bridge.currentID
    }

    private var displayedTranscriptPreviewRevision: UUID? {
        bridge.conversationTranscriptPreview?.revision
    }

    private var isDisplayingTranscriptPreview: Bool {
        bridge.conversationTranscriptPreview != nil
    }

    private var terminalHeightBinding: Binding<Double> {
        Binding(
            get: { bridge.terminalHeight },
            set: { bridge.userSetTerminalHeight($0) })
    }

    private var resolvedTerminalHeight: CGFloat {
        CGFloat(min(max(bridge.terminalHeight, 120), 400))
    }

    private func handleChatDrop(_ urls: [URL]) -> Bool {
        let files = urls.filter(\.isFileURL)
        guard !files.isEmpty else { return false }
        appendAttachmentURLs(files, needsSecurityScopedAccess: false)
        return true
    }

    /// File URLs from native drop and the paperclip picker share one ordered intake path. The picker
    /// grants scoped access only for this synchronous copy; durable generic tokens never depend on a
    /// security scope surviving after the importer callback returns.
    private func appendAttachmentURLs(
        _ urls: [URL],
        needsSecurityScopedAccess: Bool
    ) {
        var budget = ConversationAttachmentImportBudget()
        for url in urls {
            guard let maximumBytes = budget.beginAttachment() else {
                if let message = budget.takeLimitMessage() {
                    draft.text += (draft.text.isEmpty ? "" : " ") + message + " "
                }
                break
            }
            let intake = ConversationAttachmentIntake.ingest(
                url,
                conversationID: bridge.currentID,
                needsSecurityScopedAccess: needsSecurityScopedAccess,
                maximumBytes: maximumBytes)
            budget.recordCommittedBytes(intake.committedByteCount)
            if case .artifact(let reference) = intake {
                bridge.referenceArtifact(reference)
            }
            let payload = intake.promptPayload
            draft.text += (draft.text.isEmpty ? "" : " ") + payload + " "
        }
        bridge.focusComposer()
    }

    // MARK: Conversation status + controls

    /// Always occupies one fixed chat-adjacent line. Thinking used to appear/disappear as a native
    /// transcript row, which changed the viewport and contributed to bounce; moving it all the way
    /// to the window footer fixed geometry but separated it from the conversation (especially when
    /// Terminal was open). This strip keeps both the stable geometry and the correct line of sight.
    private var liveStatusStrip: some View {
        HStack(spacing: 7) {
            if transcriptStatusVisible {
                liveTurnStatus
            } else if bridge.currentReplayContinuationCategories != nil
                        || bridge.currentConversation?.forkProvenance != nil {
                HStack(spacing: 10) {
                    if let categories = bridge.currentReplayContinuationCategories {
                        ReplayContinuationStatus(categories: categories)
                    }
                    if bridge.currentReplayContinuationCategories != nil,
                       bridge.currentConversation?.forkProvenance != nil {
                        Divider().frame(height: 12)
                    }
                    if let provenance = bridge.currentConversation?.forkProvenance {
                        forkProvenanceStatus(provenance)
                    }
                }
            } else {
                Color.clear
                    .accessibilityHidden(true)
            }
            Spacer(minLength: 0)
        }
        .frame(height: 30)
        .padding(.horizontal, 16)
        .background(Color.nBg)
    }

    /// Fork provenance occupies the status strip's already-reserved height, so adding an honest
    /// lineage affordance never resizes the transcript or reintroduces typing/streaming bounce.
    @ViewBuilder
    private func forkProvenanceStatus(_ provenance: ConversationForkProvenance) -> some View {
        let availableIDs = Set(bridge.conversationsSorted.map(\.id))
        let sourceID = provenance.clickableSourceID(in: availableIDs)
        let sourceTitle = provenance.sourceTitleSnapshot?.trimmingCharacters(
            in: .whitespacesAndNewlines)
        let displayTitle = sourceTitle.flatMap { $0.isEmpty ? nil : $0 }
            ?? "another conversation"
        let label = "Forked from \(displayTitle)"
        if let sourceID {
            Button {
                bridge.openConversation(sourceID)
            } label: {
                Label(label, systemImage: "arrow.triangle.branch")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.nInfoText)
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
            .help("Open the source conversation")
            .accessibilityHint("Opens the source conversation")
            .accessibilityIdentifier("forkProvenanceStatus")
        } else {
            Label(label, systemImage: "arrow.triangle.branch")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help("The source conversation is not available on this Mac")
                .accessibilityHint("The source conversation is unavailable")
                .accessibilityIdentifier("forkProvenanceStatus")
        }
    }

    /// `ViewThatFits` only measures non-interactive replicas. The interactive controls exist once,
    /// inside `AnyLayout`, so a width change moves the same popover hosts between full, wrapped, and
    /// compact tiers without losing an action.
    private var conversationControlsBar: some View {
        ZStack(alignment: .leading) {
            ViewThatFits(in: .horizontal) {
                fullControlBarProbe
                    .preference(key: ControlBarTierKey.self, value: .full)
                wrappedControlBarProbe
                    .preference(key: ControlBarTierKey.self, value: .wrapped)
                Color.clear
                    .frame(width: 1, height: 1)
                    .preference(key: ControlBarTierKey.self, value: .compact)
            }
            .hidden()
            .frame(height: 0)
            .clipped()
            .disabled(true)
            .accessibilityHidden(true)
            conversationControlLayout
        }
        .onPreferenceChange(ControlBarTierKey.self) { controlBarTier = $0 }
        .frame(maxWidth: .infinity, alignment: .leading)
        .font(.caption)
        // Tier measurement and live content must receive the same width in every state. Changing
        // this inset as the selected tier changed made the boundary oscillate between tiers.
        .padding(.horizontal, CompactControlBarContract.horizontalPadding)
        .padding(.vertical, controlBarTier.stacksRows ? 6 : 3)
        .background(Color.nBg)
    }

    /// Intrinsic-width replica of the complete one-line bar. The fixed size is important: a Spacer
    /// would otherwise accept the proposed width while its children overflow, causing
    /// `ViewThatFits` to report a false fit (the bug that clipped the rightmost metrics).
    private var fullControlBarProbe: some View {
        let permissionOption = PermissionPresentation.option(
            mode: bridge.permissionMode,
            access: bridge.currentModelAccess)
        return HStack(spacing: 8) {
            providerWarning(includesText: true)
            MechanicianControlDeck {
                MechanicianControlTrigger(
                    title: bridge.modelDisplayName(for: bridge.selectedModelSelection),
                    systemImage: "cpu",
                    showsChevron: true,
                    maxTitleWidth: 160)
                MechanicianControlDivider()
                MechanicianControlTrigger(
                    title: AgentBridge.effortLabel(
                        bridge.effortSelectionID, access: bridge.currentModelAccess),
                    systemImage: "speedometer",
                    showsChevron: true)
                if bridge.showsUltraPill {
                    MechanicianControlDivider()
                    MechanicianControlTrigger(
                        title: "Ultra",
                        systemImage: "point.3.connected.trianglepath.dotted",
                        active: bridge.ultracode)
                }
                MechanicianControlDivider()
                MechanicianControlTrigger(
                    title: permissionOption.title,
                    systemImage: "shield",
                    showsChevron: true,
                    active: bridge.permissionModeAppliesNextTurn,
                    badge: bridge.permissionModeAppliesNextTurn ? "NEXT" : nil)
            }
            HStack(spacing: 10) {
                backgroundWorkIndicator(compact: false)
                contextMeter
                ioCounter
                // The probe must carry everything the live bar carries. A readout present in one
                // and not the other makes the measured width a lie, which is the exact bug the note
                // on `fullControlBarProbe` records about Spacer.
                windowSizeReadout
                if bridge.provider == "codex" {
                    Text(codexPlanLabel)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    /// Intrinsic-width replica of the ordinary two-row tier. If even its primary row cannot fit,
    /// the live controls switch to their icon-led compact presentation and move every metric below.
    private var wrappedControlBarProbe: some View {
        let permissionOption = PermissionPresentation.option(
            mode: bridge.permissionMode,
            access: bridge.currentModelAccess)
        return HStack(spacing: 8) {
            providerWarning(includesText: false)
            MechanicianControlDeck {
                MechanicianControlTrigger(
                    title: bridge.modelDisplayName(for: bridge.selectedModelSelection),
                    systemImage: "cpu",
                    showsChevron: true,
                    maxTitleWidth: 110,
                    wrapsTitle: true)
                MechanicianControlDivider()
                MechanicianControlTrigger(
                    title: AgentBridge.effortLabel(
                        bridge.effortSelectionID, access: bridge.currentModelAccess),
                    systemImage: "speedometer",
                    showsChevron: true,
                    maxTitleWidth: 76,
                    wrapsTitle: true)
                if bridge.showsUltraPill {
                    MechanicianControlDivider()
                    MechanicianControlTrigger(
                        title: "Ultra",
                        systemImage: "point.3.connected.trianglepath.dotted",
                        active: bridge.ultracode,
                        wrapsTitle: true)
                }
                MechanicianControlDivider()
                MechanicianControlTrigger(
                    title: permissionOption.title,
                    systemImage: "shield",
                    showsChevron: true,
                    active: bridge.permissionModeAppliesNextTurn,
                    maxTitleWidth: 110,
                    badge: bridge.permissionModeAppliesNextTurn ? "NEXT" : nil,
                    wrapsTitle: true)
            }
            contextMeter
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    /// Wrapped, the bar becomes two rows: controls and capacity together on the first, secondary
    /// status on the second.
    ///
    /// Stacking both groups flush left left a large dead area on the right and read as unfinished;
    /// the earlier left-deck-over-right-metrics arrangement read as a diagonal accident. The fix is
    /// to wrap the *least* important items rather than all of them — the context meter is the most
    /// glanced number here and pairs with the model controls, so it stays on the primary row.
    private var conversationControlLayout: some View {
        let stacked = controlBarTier.stacksRows
        let compact = controlBarTier.usesCompactControls
        let outerLayout = stacked
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 5))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 8))
        return outerLayout {
            HStack(spacing: 8) {
                providerWarning(includesText: controlBarTier == .full)
                MechanicianControlDeck {
                    ModelPickerButton(
                        bridge: bridge,
                        isWindowOrderTransitioning: $isModelSelectionTransitioning,
                        compact: compact,
                        wrapsTitle: controlBarTier == .wrapped)
                        .guidedHelpTarget(.conversationModelControl, registry: guideRegistry)
                    MechanicianControlDivider()
                    ConversationEffortControl(
                        bridge: bridge,
                        compact: compact,
                        wrapsTitle: controlBarTier == .wrapped)
                        .guidedHelpTarget(.conversationEffortControl, registry: guideRegistry)
                    if bridge.showsUltraPill {
                        MechanicianControlDivider()
                        ultraButton(
                            wrapped: controlBarTier == .wrapped,
                            compact: compact)
                    }
                    MechanicianControlDivider()
                    ConversationPermissionControl(
                        bridge: bridge,
                        compact: compact,
                        wrapsTitle: controlBarTier == .wrapped)
                        .guidedHelpTarget(.conversationPermissionControl, registry: guideRegistry)
                }
                .disabled(isModelSelectionTransitioning)
                .layoutPriority(2)
                if controlBarTier == .wrapped {
                    contextMeter
                }
            }
            .frame(maxWidth: stacked ? .infinity : nil, alignment: .leading)

            controlBarTrailingItems(tier: controlBarTier)
        }
    }

    @ViewBuilder
    private func providerWarning(includesText: Bool) -> some View {
        if bridge.mode != "sdk" {
            HStack(spacing: 5) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(
                        size: ProviderWarningPresentation.iconSize,
                        weight: .semibold))
                    .frame(
                        width: ProviderWarningPresentation.frameSize,
                        height: ProviderWarningPresentation.frameSize)
                    .accessibilityHidden(true)
                if includesText {
                    Text(providerStatusWarning)
                        .font(.caption2)
                        .lineLimit(1)
                }
            }
            .foregroundStyle(Color.nWarningText)
            .help(providerStatusWarning)
            .accessibilityLabel(providerStatusWarning)
        }
    }

    /// On one line these sit at the trailing edge, opposite the deck. Wrapped onto a second line they
    /// used to stay right-aligned under a left-aligned deck — a diagonal, with one row in a surface
    /// and the other floating loose, which read as an accident rather than a decision. Wrapped, they
    /// share the deck's left edge and its surface treatment, so the bar reads as two matched tiers.
    private func controlBarTrailingItems(tier: ControlBarTier) -> some View {
        return Group {
            if tier == .compact {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        contextMeter
                        Spacer(minLength: 6)
                        ioCounter
                        windowSizeReadout
                    }
                    .frame(maxWidth: .infinity)
                    HStack(spacing: 8) {
                        backgroundWorkIndicator(compact: true)
                        Spacer(minLength: 6)
                        if bridge.provider == "codex" {
                            Text(codexPlanLabel)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            } else if tier == .wrapped {
                // The context meter has moved up to the controls row, so this tier carries only the
                // secondary readouts — anchored at both edges so the row reaches the right margin.
                HStack(spacing: 10) {
                    backgroundWorkIndicator(compact: false)
                    Spacer(minLength: 8)
                    ioCounter
                    windowSizeReadout
                    if bridge.provider == "codex" {
                        Text(codexPlanLabel)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
                .frame(maxWidth: .infinity)
            } else {
                HStack(alignment: .center, spacing: 10) {
                    backgroundWorkIndicator(compact: false)
                    contextMeter
                    ioCounter
                    windowSizeReadout
                    if bridge.provider == "codex" {
                        Text(codexPlanLabel)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    private var effectivePlanMode: Bool {
        if let active = bridge.activePermissionMode { return active == "plan" }
        return bridge.permissionMode == "plan"
    }

    private func ultraButton(wrapped: Bool, compact: Bool) -> some View {
        let active = bridge.ultracode
        return Button {
            bridge.setUltra(!active)
        } label: {
            MechanicianControlTrigger(
                title: compact ? "" : "Ultra",
                systemImage: "point.3.connected.trianglepath.dotted",
                active: active,
                wrapsTitle: wrapped)
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help(ultraHelp(active: active))
        .accessibilityLabel("Ultra mode")
        .accessibilityValue(active ? "On" : "Off")
    }

    private func ultraHelp(active: Bool) -> String {
        let action = active ? "Disable" : "Enable"
        switch bridge.currentModelAccess {
        case .claudeSubscription, .anthropicAPI, .claudeVertex, .claudeBedrock:
            return "\(action) Claude Ultra (Extra High reasoning + proactive agent workflows)"
        case .codexSubscription:
            return "\(action) Codex Ultra (maximum reasoning + automatic task delegation)"
        case .openAIAPI:
            return "Ultra is unavailable for this account"
        }
    }

    private var planModeBanner: some View {
        HStack(spacing: 7) {
            Image(systemName: "list.bullet.clipboard.fill")
                .foregroundStyle(Color.nInfoText)
            Text("Plan mode")
                .font(.system(size: 12, weight: .semibold))
            Text("Read-only until you approve the plan")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
            if bridge.canExitPlanMode {
                Button("Exit") { bridge.permissionMode = "default" }
                    .buttonStyle(PillButtonStyle(kind: .plain))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color.nAccent.opacity(0.08))
        .overlay(Divider(), alignment: .top)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Plan mode, read-only until you approve the plan")
    }

    private var providerStatusWarning: String {
        switch bridge.provider {
        case "codex":
            return bridge.loggedIn ? "Codex disconnected" : "Sign in to Codex"
        case "openai":
            return "No OpenAI API key"
        default:
            switch bridge.authMode {
            case "subscription": return "Claude disconnected"
            case "vertex": return "Google Vertex sign-in required"
            default: return "No Anthropic API key"
            }
        }
    }

    @ViewBuilder
    private var ioCounter: some View {
        if bridge.provider != "codex" || bridge.usageIn > 0 || bridge.usageOut > 0 {
            Text("\(fmtTokens(bridge.usageIn)) in / \(fmtTokens(bridge.usageOut)) out")
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .help("Tokens sent and received in this conversation.")
        }
    }

    /// The window's size, in the status bar.
    ///
    /// Asked for while reporting two layout problems that both came down to how wide the window was
    /// against how the columns split it. "The toolbar looks wrong at 1566 by 900" is a report
    /// somebody can act on; "the toolbar looks wrong" is a screenshot and a guess.
    ///
    /// Points, not pixels, because points are what every layout constant in this app is written in —
    /// a Retina number here would be twice every figure a person would compare it against.
    @ViewBuilder
    private var windowSizeReadout: some View {
        let size = bridge.windowContentSize
        if size.width >= 1, size.height >= 1 {
            Text(verbatim: "\(Int(size.width.rounded()))×\(Int(size.height.rounded()))")
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .help("The window's content size in points, excluding the title bar.")
                .accessibilityLabel("Window size")
                .accessibilityValue(
                    "\(Int(size.width.rounded())) by \(Int(size.height.rounded())) points")
        }
    }

    private var codexPlanLabel: String {
        if let plan = bridge.codexPlanType, !plan.isEmpty {
            return "Codex \(plan.capitalized)"
        }
        return bridge.loggedIn ? "Codex subscription" : "Codex offline"
    }

    /// Peripheral-awareness chips: work happening OUTSIDE the current view. Click to jump to it,
    /// absent when nothing is cooking.
    ///
    /// Do not expose one aggregate "N running" count here. A conversation, a scheduled task and the
    /// several OS processes behind one dev server are different units; adding them produced numbers
    /// such as "5 running" that looked like five agents or messages. Conversations retain a real
    /// count, process-backed work gets a category label, and deliberately idle waits name the task
    /// that is waiting.
    @ViewBuilder
    private func backgroundWorkIndicator(compact: Bool) -> some View {
        let bgTurns = bridge.runningConvs.filter { $0 != bridge.currentID }
        let ambientRunning = ambient.tasks.filter { $0.runNow == true }
        // Scoped to what you are reading. The Schedule window remains process-wide, so nothing an
        // agent left running anywhere becomes unreachable — it just stops being counted here.
        let processes = backgroundProcesses.processes(for: bridge.currentID).count
        let summary = BackgroundWorkSummary(
            backgroundTurns: bgTurns.count,
            ambientTasksRunning: ambientRunning.count,
            trackedProcesses: processes,
            armedWaits: bridge.store.summaries.filter { $0.armedWaitSummary != nil }.count)
        let waiting = summary.waiting

        if !summary.isEmpty {
            HStack(spacing: 5) {
                if summary.backgroundTurns > 0 {
                    Button {
                        if let first = bgTurns.first {
                            ActiveWorkspace.shared.open(.conversation(first))
                        }
                    } label: {
                        HStack(spacing: 5) {
                            OrbitingDots(diameter: 12)
                            Text(compact
                                 ? "\(summary.backgroundTurns)"
                                 : "\(summary.backgroundTurns) "
                                    + (summary.backgroundTurns == 1
                                       ? "conversation working" : "conversations working"))
                                .foregroundStyle(Color.nInfoText)
                        }
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Capsule().fill(Color.nAccent.opacity(0.16)))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("\(summary.backgroundTurns) background conversation"
                          + "\(summary.backgroundTurns == 1 ? " is" : "s are") working"
                          + ". Click to open the first one.")
                    .accessibilityLabel(
                        "\(summary.backgroundTurns) background conversation"
                        + "\(summary.backgroundTurns == 1 ? "" : "s") working")
                }
                if summary.hasManagedBackgroundWork {
                    Button { openWindow(id: "ambient") } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "gearshape.2")
                                .font(.system(size: 10, weight: .medium))
                            Text(compact ? "Work" : summary.managedBackgroundLabel)
                        }
                        .foregroundStyle(Color.nInfoText)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Capsule().fill(Color.nAccent.opacity(0.16)))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help(backgroundWorkHelp(
                        ambient: ambientRunning.count, processes: processes))
                    .accessibilityLabel(summary.managedBackgroundAccessibilityLabel)
                }
                if waiting > 0 {
                    Button { openWindow(id: "ambient") } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "hourglass")
                                .font(.system(size: 10, weight: .medium))
                            Text(compact
                                 ? "\(waiting)"
                                 : "\(waiting) \(waiting == 1 ? "task" : "tasks") waiting")
                        }
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Capsule().fill(Color.nText.opacity(0.10)))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("\(waiting) conversation\(waiting == 1 ? " is" : "s are") waiting on a "
                          + "trigger. Click to see what each is waiting for, resume it now, or "
                          + "cancel it. Waiting consumes nothing.")
                    .accessibilityLabel(
                        "\(waiting) conversation\(waiting == 1 ? "" : "s") waiting on a trigger")
                }
            }
        }
    }

    private func backgroundWorkHelp(ambient: Int, processes: Int) -> String {
        var parts: [String] = []
        if ambient > 0 { parts.append("\(ambient) ambient task\(ambient == 1 ? "" : "s") running") }
        if processes > 0 {
            parts.append("\(processes) tracked process\(processes == 1 ? "" : "es")"
                         + " from agent-started commands")
        }
        return parts.joined(separator: " · ")
            + ". Click to inspect or stop this background work."
    }

    /// A live context-window fill meter — makes the (1M) window's use visible.
    @ViewBuilder
    private var contextMeter: some View {
        if bridge.contextTokens > 0, let maxTok = bridge.contextWindowMax, maxTok > 0 {
            // Measure against the point where the provider will actually compact, when it reports
            // one. Showing fill against the model's maximum is what made compaction look broken:
            // the meter read 40% and the conversation summarized itself anyway.
            let threshold = bridge.contextCompactionThreshold
            let limit = threshold ?? maxTok
            let frac = min(1.0, Double(bridge.contextTokens) / Double(limit))
            HStack(spacing: 5) {
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.nMuted.opacity(0.35)).frame(width: 46, height: 5)
                    Capsule().fill(frac > 0.9 ? Color.red : frac > 0.75 ? Color.orange : Color.nAccent)
                        .frame(width: max(2, 46 * frac), height: 5)
                }
                Text("\(fmtTokens(bridge.contextTokens))/\(fmtTokens(limit))")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .fixedSize(horizontal: true, vertical: false)
            .help(threshold == nil
                  ? "Context window: \(bridge.contextTokens) of \(maxTok) tokens used "
                    + "(\(Int(frac * 100))%)"
                  : "\(bridge.contextTokens) of \(limit) tokens used (\(Int(frac * 100))%). "
                    + "Earlier messages are summarized at \(limit), which is where this model's "
                    + "\(fmtTokens(maxTok)) window is set to compact.")
        } else if bridge.provider == "codex" {
            Text("Context —")
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .help("Codex has not reported context-window usage for this conversation and model yet.")
        }
    }

    private func fmtTokens(_ n: Int) -> String { AgentBridge.formattedTokenCount(n) }


    private var hasMessages: Bool {
        displayedTranscriptEntries.contains {
            $0.kind == .user || $0.kind == .assistant || $0.kind == .review
        }
    }

    /// Regeneration mutates this conversation by rewinding to the prompt before `entry`. Only offer
    /// it when that assistant row is literally the transcript tail; a later user prompt or terminal
    /// error must never be discarded by an older/partial assistant row's Retry button.
    private func canRetryAssistant(_ entry: TranscriptEntry) -> Bool {
        !isDisplayingTranscriptPreview
            && entry.kind == .assistant
            && bridge.entries.last?.id == entry.id
    }

    /// The provider- or on-device-authored follow-up — click to add it to the composer.
    private func suggestionBar(_ suggestion: ConversationSuggestedPrompt) -> some View {
        Button {
            let acceptedDraft = ChatInput.appending(
                suggestion: suggestion.text,
                to: draft.text)
            if bridge.acceptSuggestedPrompt(suggestion, draft: acceptedDraft) {
                draft.text = acceptedDraft
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "lightbulb.fill").font(.caption2).foregroundStyle(Color.nInfoText)
                Text(suggestion.text).font(.caption).lineLimit(1)
                Spacer()
                Image(systemName: "arrow.up.left").font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.nAccent.opacity(0.12)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.nAccent.opacity(0.3)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 8)
        .help("Add this suggested follow-up to your message")
        .accessibilityLabel("Suggested follow-up: \(suggestion.text)")
    }

    private func elapsedString(_ t: TimeInterval) -> String {
        let s = Int(t)
        return s < 60 ? "\(s)s" : String(format: "%d:%02d", s / 60, s % 60)
    }

    @ViewBuilder
    private var transcript: some View {
        if hasMessages {
            // Keep the native transcript viewport's height stable for the whole turn. The old
            // status strip lived between the table and composer, so appearing at turn start and
            // disappearing at terminal state resized the clip view by ~34 points. Bottom pinning
            // correctly followed both resizes, but the entire response visibly jumped up and then
            // back down. Live status now occupies the always-present status bar instead.
            // The find bar sits above the transcript, not inside it: the transcript viewport's
            // height must stay stable for a whole turn (the comment above), and a bar that appeared
            // inside it would resize the clip view exactly the way the old status strip did.
            VStack(spacing: 0) {
                transcriptFindBar
                transcriptScroll
            }
        } else {
            emptyState
        }
    }

    /// A new-conversation example — hover-lit, and DISABLED (visibly dimmed) until the agent is ready,
    /// so it never reads as dead UI (clicking did nothing before the agent connected).
    private struct HintCard: View {
        let example: NewConversationExample
        let enabled: Bool
        let action: () -> Void
        @State private var hovering = false
        var body: some View {
            Button(action: action) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: example.systemImage)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Color.nInfoText)
                        .frame(width: 20, height: 20)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(example.title).font(.system(size: 13, weight: .semibold))
                        Text(example.prompt)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.up.right")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(hovering && enabled ? Color.nElevated : Color.nSurface))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.nMuted.opacity(0.5)))
            .disabled(!enabled)
            .help(example.prompt)
            .accessibilityLabel("\(example.title): \(example.prompt)")
            .onHover { hovering = $0 }
        }
    }

    @ViewBuilder
    private func newConversationTitle(_ title: String) -> some View {
        if MechanicianTypography.isProductWordmark(title) {
            HStack(spacing: 12) {
                if let applicationIcon = NSApp.applicationIconImage {
                    Image(nsImage: applicationIcon)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(width: 56, height: 56)
                        .accessibilityHidden(true)
                }
                Text(MechanicianTypography.productName)
                    .font(MechanicianTypography.newConversationWordmarkFont)
                    .tracking(MechanicianTypography.newConversationWordmarkTracking)
            }
        } else {
            Text(title).font(.largeTitle.weight(.semibold))
        }
    }

    private var emptyState: some View {
        let content = NewConversationExamples.content(
            projectID: bridge.projectID,
            cwd: bridge.cwd,
            projects: projectStore.projects)
        return VStack(spacing: 16) {
            Spacer()
            newConversationTitle(content.title)
            Text(content.subtitle)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 560)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 8)], spacing: 8) {
                ForEach(content.examples) { example in
                    HintCard(example: example, enabled: bridge.isReady) {
                        bridge.send(example.prompt)
                    }
                }
            }
            .frame(maxWidth: 620)
            let instructionTarget = WorkspaceInstructionsPresentation.target(
                projectID: bridge.projectID,
                cwd: bridge.cwd,
                projects: projectStore.projects)
            if instructionTarget != nil || content.offersFolderPicker {
                HStack(spacing: 16) {
                    if instructionTarget != nil {
                        Button {
                            bridge.presentWorkspaceInstructions()
                        } label: {
                            Label(
                                WorkspaceInstructionsPresentation.actionTitle,
                                systemImage: WorkspaceInstructionsPresentation.systemImage)
                        }
                        .help("Add or edit standing instructions for this workspace")
                        .accessibilityIdentifier("workspaceManagement.instructions")
                    }
                    if content.offersFolderPicker {
                        Button {
                            bridge.chooseFolder()
                        } label: {
                            Label("Working with files or code? Open a folder", systemImage: "folder")
                        }
                        .disabled(!bridge.isReady)
                        .help("Open a folder as a workspace")
                        .accessibilityIdentifier("workspaceManagement.folder")
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.nInfoText)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private func loadMigrationNotice() {
        let d = UserDefaults.standard
        guard d.bool(forKey: "pendingMigrationNotice") else { return }
        let conv = d.integer(forKey: "migratedConversationCount")
        let proj = d.integer(forKey: "migratedProjectCount")
        if conv > 0, proj > 0 { migrationNotice = (conv, proj) }
    }

    private func dismissMigrationNotice() {
        UserDefaults.standard.removeObject(forKey: "pendingMigrationNotice")
        withAnimation { migrationNotice = nil }
    }
    @ViewBuilder private func migrationBanner(_ n: (conv: Int, proj: Int)) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "square.grid.2x2").foregroundStyle(Color.nInfoText)
            Text("Created \(n.proj) workspace\(n.proj == 1 ? "" : "s") from the working folder\(n.conv == 1 ? "" : "s") used by \(n.conv) existing conversation\(n.conv == 1 ? "" : "s"). Your conversations were not changed.")
                .font(.system(size: 12)).foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("Review Workspaces") { openWindow(id: "projects"); dismissMigrationNotice() }
                .buttonStyle(PillButtonStyle(kind: .accent))
            Button { dismissMigrationNotice() } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless).foregroundStyle(.secondary).help("Dismiss")
                .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Color.nSurface)
        .overlay(Divider(), alignment: .bottom)
    }

    private func dismissReclaimNotice(_ receipt: StorageRollbackReclaimCoordinator.Receipt) {
        withAnimation {
            reclaimNoticeDismissedAt = StorageRollbackReclaimNotice.dismissalMark(for: receipt)
        }
    }
    @ViewBuilder
    private func reclaimBanner(_ receipt: StorageRollbackReclaimCoordinator.Receipt) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "internaldrive").foregroundStyle(Color.nInfoText)
                .accessibilityHidden(true)
            Text(StorageRollbackReclaimNotice.message(receipt))
                .font(.system(size: 12)).foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("Show Trash") {
                if let trash = try? FileManager.default.url(
                    for: .trashDirectory, in: .userDomainMask, appropriateFor: nil, create: false) {
                    NSWorkspace.shared.open(trash)
                }
                dismissReclaimNotice(receipt)
            }
            .buttonStyle(PillButtonStyle(kind: .accent))
            Button { dismissReclaimNotice(receipt) } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless).foregroundStyle(.secondary).help("Dismiss")
                .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Color.nSurface)
        .overlay(Divider(), alignment: .bottom)
        .accessibilityIdentifier("storageReclaimNotice")
    }

    private var transcriptScroll: some View {
        let projection = appKitTranscriptProjection
        return AppKitTranscriptHost(
            chunks: projection.chunks,
            chunksGeneration: projection.chunksGeneration,
            projectionCacheID: projection.cacheID,
            projectionRevision: projection.projectionRevision,
            tailUpdate: projection.tailUpdate,
            workflowUpdate: projection.workflowUpdate,
            pin: pin,
            revealRequest: bridge.revealRequest,
            onRevealResult: { token, succeeded in
                if !succeeded { bridge.revealFailed(token: token) }
            },
            onPresentationSync: {
                bridge.transcriptNativePresentationDidSynchronize(
                    conversationID: displayedTranscriptConversationID)
            },
            activityDetail: { index in
                guard let entry = renderedTranscriptEntry(at: index),
                      displayedTranscriptEntries.indices.contains(index) else {
                    return AnyView(EmptyView())
                }
                return AnyView(ExpandedToolContent(
                    entry: entry,
                    capturedImage: bridge.toolImages[entry.id],
                    persistedImageURL: bridge.persistedToolImageURL(for: entry),
                    chatScale: chatScale)
                    .equatable())
            },
            retryAssistant: { index in
                guard !isDisplayingTranscriptPreview else { return }
                guard bridge.entries.indices.contains(index) else { return }
                bridge.retryAssistant(bridge.entries[index])
            },
            forkAssistant: { index in
                guard !isDisplayingTranscriptPreview else { return }
                guard bridge.entries.indices.contains(index) else { return }
                bridge.forkAssistant(bridge.entries[index])
            }
        ) { index in
            guard let entry = renderedTranscriptEntry(at: index) else {
                return AnyView(EmptyView())
            }
            return AnyView(bubble(entry)
                .frame(maxWidth: .infinity, alignment: .leading)
                .environmentObject(bridge))
        }
        .onChange(of: bridge.entries.last(where: { $0.kind == .user })?.id) { _, _ in
            landAtBottom()
        }
        .onChange(of: bridge.provisionalUserEntryForCurrentConversation?.id) { _, _ in
            landAtBottom()
        }
        .onChange(of: bridge.provisionalGuidanceEntriesForCurrentConversation.last?.id) { _, _ in
            landAtBottom()
        }
        // A conversation's matches belong to that conversation, so a switch closes the bar rather
        // than leaving it open over a stale count.
        .onChange(of: bridge.currentID) { _, _ in landAtBottom(); bridge.closeFind() }
        // A streamed turn changes what there is to find; keep the count true without moving anyone.
        .onChange(of: bridge.transcriptEntriesGeneration) { _, _ in
            bridge.refreshFindForEntriesChange()
        }
        .onAppear {
            pin.onReattach = { pin.pinToBottom() }
            landAtBottom()
        }
    }

    /// The find bar, shown above the transcript. Escape closes it, Return steps forward, and
    /// ⇧Return steps back — the three keys a Mac find bar answers to without being told.
    @ViewBuilder var transcriptFindBar: some View {
        if bridge.find.isShowing {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField("Find in conversation", text: Binding(
                    get: { bridge.find.query },
                    set: { bridge.runFind(query: $0) }))
                    .textFieldStyle(.plain)
                    .focused($findFieldFocused)
                    .onSubmit { bridge.findNext() }
                    .accessibilityLabel("Find in conversation")
                if let label = bridge.find.countLabel {
                    Text(label)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .accessibilityLabel(label)
                }
                Button { bridge.findPrevious() } label: { Image(systemName: "chevron.up") }
                    .buttonStyle(.borderless)
                    .disabled(bridge.find.matches.isEmpty)
                    .help("Find previous (⇧⌘G)")
                    .accessibilityLabel("Find previous")
                Button { bridge.findNext() } label: { Image(systemName: "chevron.down") }
                    .buttonStyle(.borderless)
                    .disabled(bridge.find.matches.isEmpty)
                    .help("Find next (⌘G)")
                    .accessibilityLabel("Find next")
                Button("Done") { bridge.closeFind() }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Close find bar")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.nSurface)
            .overlay(Divider(), alignment: .bottom)
            .onChange(of: bridge.findFocusToken) { _, _ in findFieldFocused = true }
            .onAppear { findFieldFocused = true }
            .onExitCommand { bridge.closeFind() }   // Escape
        }
    }

    private var renderedTranscriptEntries: [TranscriptEntry] {
        if isDisplayingTranscriptPreview {
            return displayedTranscriptEntries
        }
        return transcriptEntriesForRendering(
            durable: displayedTranscriptEntries,
            provisionalRoot: bridge.provisionalUserEntryForCurrentConversation,
            provisionalGuidance: bridge.provisionalGuidanceEntriesForCurrentConversation)
    }

    private func renderedTranscriptEntry(at index: Int) -> TranscriptEntry? {
        let entries = renderedTranscriptEntries
        return entries.indices.contains(index) ? entries[index] : nil
    }

    private var appKitTranscriptProjection: AppKitTranscriptProjection {
        let provisionalRoot = bridge.provisionalUserEntryForCurrentConversation
        let provisionalGuidance = bridge.provisionalGuidanceEntriesForCurrentConversation
        let renderedEntries = renderedTranscriptEntries
        let inputs = TranscriptProjectionInputs(
            conversationID: displayedTranscriptConversationID,
            previewRevision: displayedTranscriptPreviewRevision,
            chatScale: chatScale,
            isStreaming: !isDisplayingTranscriptPreview && bridge.isStreaming,
            cwd: bridge.cwd,
            find: bridge.find,
            expandedTools: bridge.expandedTools,
            toolImageIDs: Set(bridge.toolImages.keys),
            pendingGuidanceEntryIDs: bridge.pendingGuidanceEntryIDsForPresentation,
            provisionalRoot: provisionalRoot,
            provisionalGuidance: provisionalGuidance)
        return transcriptProjectionCache.project(
            key: inputs,
            generation: bridge.transcriptEntriesGeneration,
            append: isDisplayingTranscriptPreview ? nil : bridge.transcriptTailAppend,
            conversationID: displayedTranscriptConversationID,
            tailEntry: displayedTranscriptEntries.last,
            canonical: {
                canonicalAppKitTranscriptRows(renderedEntries)
            },
            tailChunk: { entry, append in
                guard !isDisplayingTranscriptPreview,
                      provisionalRoot == nil,
                      provisionalGuidance.isEmpty,
                      bridge.entries.last?.id == entry.id else { return nil }
                let index = bridge.entries.index(before: bridge.entries.endIndex)
                return appKitTranscriptChunk(
                    for: TranscriptRowSpan(kind: .entry, range: index..<(index + 1)),
                    in: bridge.entries,
                    tailAppend: append)
            },
            workflowChunk: { sourceIndex, toolUseID in
                guard renderedEntries.indices.contains(sourceIndex),
                      renderedEntries[sourceIndex].toolUseId == toolUseID else { return nil }
                return appKitTranscriptChunk(
                    for: TranscriptRowSpan(
                        kind: .entry,
                        range: sourceIndex..<(sourceIndex + 1)),
                    in: renderedEntries,
                    conversationID: displayedTranscriptConversationID,
                    isPreview: isDisplayingTranscriptPreview,
                    tailAppend: nil)
            })
    }

    private func canonicalAppKitTranscriptRows(
        _ renderedEntries: [TranscriptEntry]
    ) -> [AppKitTranscriptChunk] {
        return transcriptRowSpans(renderedEntries).compactMap {
            appKitTranscriptChunk(
                for: $0,
                in: renderedEntries,
                conversationID: displayedTranscriptConversationID,
                isPreview: isDisplayingTranscriptPreview,
                tailAppend: nil)
        }
    }

    private func appKitTranscriptChunk(
        for span: TranscriptRowSpan,
        in renderedEntries: [TranscriptEntry],
        conversationID: UUID? = nil,
        isPreview: Bool = false,
        tailAppend: TranscriptTailAppend?
    ) -> AppKitTranscriptChunk? {
            let index = span.range.lowerBound
            let entry = renderedEntries[index]
            if span.kind == .entry,
               ContextLimitFailureProjection.subsumesCompactionFailure(
                   entry,
                   in: renderedEntries
               ) {
                return nil
            }
            let rowID = AnyHashable(TranscriptEntryRowID(
                conversationID: conversationID ?? bridge.currentID,
                entryID: entry.id))

            if span.kind == .activity {
                var hasher = Hasher()
                hasher.combine(chatScale)
                var actions: [AppKitActivityAction] = []
                actions.reserveCapacity(span.range.count)
                for actionIndex in span.range {
                    let action = renderedEntries[actionIndex]
                    let state: AppKitActivityAction.State
                    // A declined call resolves to `.failed`, because the transport reports the
                    // refusal as an error. The refusal is the more specific truth and wins.
                    if action.toolRefused == true {
                        state = .refused
                    } else {
                        switch action.resolvedToolState {
                        case .running: state = .running
                        case .succeeded: state = .succeeded
                        case .failed: state = .failed
                        case .stopped: state = .stopped
                        }
                    }
                    hasher.combine(action.id)
                    hasher.combine(action.resolvedToolState.rawValue)
                    hasher.combine(action.toolRefused)
                    hasher.combine(action.isSuperseded)
                    hasher.combine(action.supersessionEventID)
                    hasher.combine(action.supersededByFrameUUID)
                    hasher.combine(bridge.toolImages[action.id] != nil)
                    hasher.combine(action.toolImage)
                    var actionHasher = Hasher()
                    actionHasher.combine(action.id)
                    actionHasher.combine(action.resolvedToolState.rawValue)
                    actionHasher.combine(action.toolRefused)
                    actionHasher.combine(action.isSuperseded)
                    actionHasher.combine(action.supersessionEventID)
                    actionHasher.combine(action.supersededByFrameUUID)
                    actionHasher.combine(bridge.toolImages[action.id] != nil)
                    actionHasher.combine(action.toolImage)
                    actions.append(AppKitActivityAction(
                        id: AnyHashable(TranscriptEntryRowID(
                            conversationID: conversationID ?? bridge.currentID,
                            entryID: action.id)),
                        sourceIndex: actionIndex,
                        toolName: action.toolName ?? "tool",
                        rawInput: action.text,
                        state: state,
                        isSuperseded: action.isSuperseded,
                        revision: actionHasher.finalize()))
                }
                return AppKitTranscriptChunk(
                    id: rowID,
                    revision: hasher.finalize(),
                    sourceIndex: index,
                    activityGroup: AppKitActivityGroup(
                        id: rowID,
                        actions: actions,
                        chatScale: chatScale))
            }

            let isTail = index == renderedEntries.count - 1
            let workflowRun: WorkflowRun?
            if entry.toolName == "Workflow", let toolUseID = entry.toolUseId {
                workflowRun = bridge.workflowRuns[toolUseID]
                    ?? bridge.workflowRuns.values.first(where: { $0.toolUseId == toolUseID })
            } else {
                workflowRun = nil
            }
            var hasher = Hasher()
            hasher.combine(entry.id)
            hasher.combine(chatScale)
            hasher.combine(bridge.provisionalUserEntryForCurrentConversation?.id == entry.id)
            // A restored or late recall disclosure can make an already-realized assistant row
            // eligible for outcome feedback without changing that assistant's own payload. Native
            // cells refresh by revision, so this presentation fact must participate in it.
            // Historical entries are immutable, so selecting a large conversation must not rescan
            // every saved String. Only the transcript tail can receive token-by-token growth.
            if isTail {
                hasher.combine(entry.text.utf8.count)
                hasher.combine(entry.toolResult?.utf8.count)
            }
            // Review rows can update behind intervening tool rows, so their authoritative result
            // cannot use the historical-tail optimization reserved for ordinary assistant prose.
            if entry.kind == .review {
                hasher.combine(entry.text)
                hasher.combine(entry.review?.status.rawValue)
                hasher.combine(entry.review?.providerReviewID)
            }
            // Tool results arrive atomically and interactive rows mutate in place. These cheap
            // transitions remain part of the row revision after an entry becomes historical.
            hasher.combine(entry.toolResult != nil)
            hasher.combine(entry.toolState?.rawValue)
            hasher.combine(entry.permDecided)
            // Find's mark is part of how this row looks, so it belongs in the row's identity.
            // Without this the row keeps its cached rendering and the highlight never appears.
            hasher.combine(bridge.find.currentMatch?.entryID == entry.id)
            hasher.combine(bridge.find.currentMatch?.occurrenceInEntry ?? -1)
            hasher.combine(bridge.find.query)
            hasher.combine(entry.permAllowed)
            hasher.combine(entry.questionDecided)
            hasher.combine(entry.toolIsError)
            hasher.combine(bridge.expandedTools.contains(entry.id))
            // Generated images are copied to durable media after their terminal event. This direct
            // row must invalidate when that reference or its live cache arrives, otherwise the
            // native host can retain the pre-image card indefinitely.
            hasher.combine(entry.toolImage)
            hasher.combine(bridge.toolImages[entry.id] != nil)
            hasher.combine(transcriptGuidanceRenderState(
                for: entry,
                isPending: entry.guidanceState == .sending
                    && bridge.guidanceIsPending(entry.id)))
            // Claude's PostCompact hook and streamed boundary have no documented relative order.
            // Either can refine this historical row after insertion, including adding expandable
            // summary text and changing its measured height, so every visible compaction field is
            // part of the native transcript cache revision.
            if entry.kind == .compaction {
                hasher.combine(entry.compactionTrigger)
                hasher.combine(entry.compactionPreTokens)
                hasher.combine(entry.compactionPostTokens)
                hasher.combine(entry.compactionSequence)
                hasher.combine(entry.compactionError)
                // A provider summary is an append-only refinement: once present, the merge path
                // never rewrites it. Presence and byte count therefore invalidate nil → summary
                // without re-hashing as much as 1 MiB of immutable history on every streamed delta.
                hasher.combine(entry.compactionSummary != nil)
                hasher.combine(entry.compactionSummary?.utf8.count)
                hasher.combine(entry.compactionSummarySource)
                hasher.combine(entry.compactionSummaryTruncated)
                hasher.combine(entry.compactionAccess)
            }
            // Only the current streaming assistant changes its completed-message action row.
            hasher.combine(isTail && entry.kind == .assistant && bridge.isStreaming)
            hasher.combine(entry.kind == .review && entry.review?.status == .running)
            // A live Workflow card GROWS its own height as agents/phases stream in, while its tool
            // entry's own fields (text/state) stay unchanged the whole time it is "running". Without
            // folding the run's live state into the row revision, the AppKit transcript never
            // re-measures this row, so the card clips into the message below it and the row height
            // is stuck. Hash the height-affecting run signals (sorted for a stable hash).
            if let run = workflowRun {
                hasher.combine(run.status.rawValue)
                hasher.combine(run.phases.count)
                hasher.combine(run.description)
                hasher.combine(run.summary)
                hasher.combine(run.outputFile)
                hasher.combine(run.error)
                for agent in run.agents.values.sorted(by: { $0.id < $1.id }) {
                    hasher.combine(agent.id)
                    hasher.combine(agent.state.rawValue)
                    hasher.combine(agent.lastToolName ?? "")   // the live tool line adds a row of height
                    hasher.combine(agent.tokens ?? -1)
                }
            }
            return AppKitTranscriptChunk(
                id: rowID,
                revision: hasher.finalize(),
                sourceIndex: index,
                hostedHeightEstimateClass: AppKitHostedHeightEstimateClass(entry: entry),
                contentMetric: entry.text.utf8.count,
                // Once terminal, this immutable historical card no longer needs to participate in
                // task-driven refreshes. A missing run remains refreshable because its launch
                // acknowledgement can arrive after the transcript tool row.
                workflowToolUseID: workflowRun?.status.isTerminal == true
                    ? nil
                    : (entry.toolName == "Workflow" ? entry.toolUseId : nil),
                assistant: entry.kind == .assistant || entry.kind == .review
                    ? AppKitAssistantContent(
                        text: entry.kind == .review
                                && entry.review?.status == .running
                                && entry.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? "Codex is reviewing the current uncommitted changes…"
                            : entry.text,
                        chatScale: chatScale,
                        isLive: !isPreview && (entry.kind == .review
                            ? entry.review?.status == .running
                            : bridge.isStreaming && entry.id == bridge.entries.last?.id),
                        canRetry: !isPreview && canRetryAssistant(entry),
                        canFork: !isPreview && entry.kind == .assistant,
                        cwd: bridge.cwd,
                        eyebrow: entry.review?.title,
                        isReview: entry.kind == .review,
                        tailAppend: tailAppend,
                        transcriptGeneration: bridge.transcriptEntriesGeneration)
                    : nil)
    }

    /// Forked conversations can share transcript-entry UUIDs. Include the conversation identity so
    /// native row measurements and reused cells can never cross a conversation switch.
    private struct TranscriptEntryRowID: Hashable {
        let conversationID: UUID?
        let entryID: UUID
    }

    private var transcriptStatusVisible: Bool {
        bridge.isStreaming || bridge.isWorking || bridge.hasRunningDelegate
    }

    private var liveTurnStatus: some View {
        let runningAgents = bridge.runningAgentCount
        let displayedStatus = bridge.delegateStatus
            ?? (bridge.isWorking ? bridge.statusLabel
                : (bridge.isStreaming ? "Responding…" : bridge.statusLabel))
        return HStack(spacing: 8) {
            OrbitingDots(diameter: 17)
            Text(displayedStatus)
                // Status-bar chrome stays at native control scale; transcript zoom must not make
                // this fixed-height lane wrap or clip and resize the transcript again.
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.nAccent.mix(with: Color.nText, by: 0.48))
                .lineLimit(1).truncationMode(.tail)
                .layoutPriority(1)
                .transaction { $0.animation = nil }
            if runningAgents > 0 {
                Label("\(runningAgents) \(runningAgents == 1 ? "agent" : "agents")", systemImage: "person.2.fill")
                    .font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Color.nInfoText)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Capsule().fill(Color.nAccent.opacity(0.18)))
                    .lineLimit(1)
                    .fixedSize()
            }
            if let start = bridge.turnStartedAt {
                TimelineView(.periodic(from: start, by: 1)) { ctx in
                    Text(elapsedString(ctx.date.timeIntervalSince(start)))
                        .font(.system(size: 12, weight: .medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
            }
        }
        .frame(minHeight: 24, alignment: .leading)
        .transition(.identity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(displayedStatus + (runningAgents > 0 ? ", \(runningAgents) working" : ""))
        .accessibilityHint(bridge.hasStoppableConversationWork
            ? "Use Stop in the composer to stop this conversation’s active work."
            : "")
    }

    /// Land at the bottom when a conversation opens or switches, including into a fresh tab. The
    /// controller's clamped settle converges as native table row heights land.
    private func landAtBottom() {
        let landing = pin.beginLanding()
        DispatchQueue.main.async {
            guard pin.canSettleLanding(landing) else { return }
            pin.pinToBottom()
        }
    }

    /// The find mark for this entry, or nil when Find is elsewhere. Word-level: a whole-row wash
    /// tells you nothing on a long message that was pasted from somewhere else.
    private func findHighlighted(_ text: String, in entry: TranscriptEntry) -> AttributedString? {
        guard !isDisplayingTranscriptPreview,
              bridge.find.isShowing, let match = bridge.find.currentMatch,
              match.entryID == entry.id else { return nil }
        return TranscriptSearch.highlighted(
            text, query: bridge.find.query, occurrence: match.occurrenceInEntry)
    }

    @ViewBuilder
    private func bubble(_ entry: TranscriptEntry) -> some View {
        switch entry.kind {
        case .user where entry.guidanceAuthor != nil:
            // An injected policy is stored as a `.user` row so it can travel the steer channel, but
            // it is not something the person said and must never be dressed as one. The right-hand
            // accent bubble is the visual signature of "you typed this"; wearing it here would make
            // the app's own words indistinguishable from theirs at a glance.
            memoryPolicyRow(entry)

        case .user:
            HStack {
                Spacer(minLength: 40)
                VStack(alignment: .trailing, spacing: 3) {
                    if !isDisplayingTranscriptPreview,
                       bridge.provisionalUserEntryForCurrentConversation?.id == entry.id {
                        HStack(spacing: 5) {
                            OrbitingDots(diameter: 11)
                            Text("Sending…")
                        }
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(Color.nInfoText)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.nAccent.opacity(0.14)))
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("Sending message")
                    }
                    if let guidanceState = entry.guidanceState {
                        let activelySending = guidanceState == .sending
                            && bridge.guidanceIsPending(entry.id)
                        let presentation: (icon: String, label: String, tint: Color) = {
                            if activelySending {
                                return ("", "Delivering guidance…", Color.nInfoText)
                            }
                            switch guidanceState {
                            case .delivered:
                                return ("arrow.triangle.turn.up.right.diamond.fill",
                                        "Guidance delivered", Color.nSuccessText)
                            case .queued:
                                return ("clock.badge.exclamationmark",
                                        "Not delivered, queued for next turn", Color.nWarningText)
                            case .sentNext:
                                return ("checkmark.circle.fill",
                                        "Sent as the next message", Color.nSuccessText)
                            case .cancelled:
                                return ("xmark.circle.fill",
                                        "Cancelled", Color.secondary)
                            case .sending:
                                return ("exclamationmark.triangle.fill",
                                        "Guidance delivery not confirmed", Color.nWarningText)
                            }
                        }()
                        let iconTone = transcriptGuidanceIconTone(
                            for: guidanceState,
                            activelySending: activelySending)
                        let iconColor = iconTone == .adaptiveHighContrast
                            ? Color(nsColor: .labelColor)
                            : presentation.tint
                        HStack(spacing: 0) {
                            HStack(spacing: 5) {
                                if activelySending {
                                    OrbitingDots(diameter: 11)
                                } else {
                                    Image(systemName: presentation.icon)
                                        .font(.system(size: 9, weight: .semibold))
                                        .foregroundStyle(iconColor)
                                }
                                Text(presentation.label)
                            }
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(presentation.tint)
                            .padding(.leading, 8)
                            .padding(.trailing, activelySending ? 6 : 8)
                            .padding(.vertical, 3)
                            .accessibilityElement(children: .combine)
                            if activelySending {
                                Rectangle()
                                    .fill(presentation.tint.opacity(0.25))
                                    .frame(width: 1, height: 13)
                                Button { bridge.redirectInFlightGuidance(entry.id) } label: {
                                    ComposerRoadSign(kind: .detour, size: 12, raised: false)
                                        .frame(width: 24, height: 22)
                                        .contentShape(Circle())
                                }
                                .buttonStyle(.plain)
                                .help("Stop current turn and redirect with this guidance")
                                .accessibilityLabel("Stop and redirect with this guidance")
                                Button { bridge.cancelInFlightGuidance(entry.id) } label: {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundStyle(presentation.tint)
                                        .frame(width: 24, height: 22)
                                        .contentShape(Circle())
                                }
                                .buttonStyle(.plain)
                                .help("Cancel guidance")
                                .accessibilityLabel("Cancel guidance")
                            }
                        }
                        .background(Capsule().fill(presentation.tint.opacity(0.14)))
                        if let reason = entry.guidanceFailureReason, !reason.isEmpty {
                            Text(reason)
                                .font(.system(size: 10.5))
                                .foregroundStyle(Color.nWarningText)
                                .multilineTextAlignment(.trailing)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    ForEach(userMessagePresentationSegments(
                        text: entry.text, imagePaths: entry.imagePaths)) { segment in
                        switch segment {
                        case .text(_, let rawText):
                            let displayText = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !displayText.isEmpty {
                                // Marked text when Find is on this entry, plain otherwise. The
                                // assistant rows get this from TextKit; a SwiftUI row has to build
                                // the attributed string itself.
                                Text(findHighlighted(displayText, in: entry) ?? AttributedString(displayText))
                                    .font(.system(size: 13 * chatScale))
                                    .padding(10)
                                    .background(RoundedRectangle(cornerRadius: 12)
                                        .fill(Color.nAccent.opacity(0.35)))
                                    .textSelection(.enabled)
                                    .accessibilityLabel("You said, \(displayText)")
                            }
                        case .image(_, let path):
                            if let image = NSImage(contentsOfFile: path) {
                                Image(nsImage: image)
                                    .resizable().aspectRatio(contentMode: .fit)
                                    .frame(maxWidth: 260 * chatScale, maxHeight: 180 * chatScale)
                                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .strokeBorder(Color.nMuted.opacity(0.5)))
                                    .onTapGesture { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
                                    .help(path)
                                    .accessibilityLabel("Attached image")
                            } else {
                                Label((path as NSString).lastPathComponent, systemImage: "photo")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        case .file(_, let reference):
                            ConversationFileAttachmentView(
                                reference: reference,
                                url: displayedTranscriptConversationID.flatMap {
                                    ConversationStore.shared.composerFileURL(
                                        conversationID: $0,
                                        reference: reference)
                                },
                                chatScale: chatScale)
                        case .artifact(_, let reference):
                            HStack(spacing: 7) {
                                Image(systemName: ArtifactActions.symbol(forType: reference.type))
                                    .foregroundStyle(Color.nInfoText)
                                Text(reference.title)
                                    .font(.system(size: 12.5 * chatScale, weight: .semibold))
                                    .lineLimit(1)
                                Text(reference.type.uppercased())
                                    .font(.system(
                                        size: 9.5 * chatScale,
                                        weight: .bold,
                                        design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color.nAccent.opacity(0.18)))
                            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(Color.nAccent.opacity(0.28)))
                            .help("Referenced artifact · \(reference.title)")
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel(
                                "Referenced \(reference.type) artifact, \(reference.title)")
                        }
                    }
                    .contextMenu {
                        Button("Copy") { copy(entry.text) }
                        Button("Edit & Resend") { draft.text = entry.text; bridge.focusComposer() }
                    }
                    // Hover-reveal copy (discoverable) — matches the assistant action row.
                    CopyButton(text: entry.text, scale: chatScale).padding(.trailing, 2)
                }
            }
        case .assistant:
            // Assistant prose is rendered by NativeAssistantCell at the table boundary. Keeping
            // this fallback empty guarantees streaming cannot accidentally re-enter the old
            // multi-pass SwiftUI hosting/measurement path.
            EmptyView()
        case .review:
            // Provider-native reviews use the same selectable native Markdown cell as assistant
            // prose, but carry their own labeled lifecycle and never enter provider history replay.
            EmptyView()
        case .system:
            // Authoritative provider metadata wins over legacy message recognition. Otherwise an
            // OpenAI/Codex quota string containing similar prose could render as a Claude card.
            if let refusal = entry.refusal {
                // Ahead of the failure/limit branches: a refusal is not a failure, and rendering it
                // as one would tell the user their account or runtime is broken when it is fine.
                refusalRow(refusal)
            } else if let failure = entry.providerFailure {
                providerFailureRow(entry, failure: failure)
            } else if let limit = entry.recognizedUsageLimit(
                for: bridge.currentConversation?.modelSelection?.access) {
                usageLimitRow(entry, limit: limit)
            } else if let warning = entry.usageWarning {
                usageWarningRow(warning)
            } else {
                VStack(spacing: 6) {
                    Text(entry.text)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                    // Retry after a failed turn: re-run the prompt that errored (only on the most
                    // recent error, so old errors in the scrollback don't sprout buttons).
                    if entry.text.lowercased().hasPrefix("error"),
                       entry.id == displayedTranscriptEntries.last?.id,
                       !isDisplayingTranscriptPreview,
                       !bridge.isStreaming,
                       let lastUser = displayedTranscriptEntries.last(where: {
                           $0.kind == .user
                       })?.text,
                       !lastUser.isEmpty {
                        MsgActionButton(icon: "arrow.clockwise", label: "Retry",
                                        help: "Re-run the prompt that failed", scale: chatScale) {
                            bridge.send(lastUser)
                        }
                    }
                }
            }
        case .compaction:
            if !ContextLimitFailureProjection.subsumesCompactionFailure(
                entry,
                in: displayedTranscriptEntries
            ) {
                compactionRow(entry)
            }
        case .tool:
            toolRow(entry)
        case .permission:
            permissionRow(entry)
        case .question:
            questionRow(entry)
        }
    }

    private func compactionRow(_ entry: TranscriptEntry) -> some View {
        let failed = entry.compactionError != nil
        let failurePresentation = entry.compactionError.map(CompactionFailurePresentation.from)
        let tokenDetail: String? = {
            guard let pre = entry.compactionPreTokens,
                  let post = entry.compactionPostTokens else { return nil }
            return "\(fmtTokens(pre)) → \(fmtTokens(post)) tokens"
        }()
        let trigger = entry.compactionTrigger == "manual" ? "Manual" : nil
        let details = [trigger, tokenDetail].compactMap { $0 }
        return CompactionTranscriptRow(
            failed: failed,
            failureMessage: failurePresentation?.message,
            detail: details.isEmpty ? nil : details.joined(separator: " · "),
            summary: entry.compactionSummary,
            summarySource: entry.compactionSummarySource,
            summaryTruncated: entry.compactionSummaryTruncated == true,
            access: entry.compactionAccess,
            chatScale: chatScale)
    }


    private func providerFailureRow(_ entry: TranscriptEntry, failure: ProviderFailure) -> some View {
        let isLatestFailure = entry.id == displayedTranscriptEntries.last?.id
        let failedPrompt = isLatestFailure
            ? displayedTranscriptEntries.last(where: { $0.kind == .user })?.text ?? ""
            : nil
        let retryPrompt = !isDisplayingTranscriptPreview && bridge.canRetryProviderFailure(failure)
            ? failedPrompt : nil
        let compactionFailure = ContextLimitFailureProjection.precedingCompactionFailure(
            for: entry,
            in: displayedTranscriptEntries)
        let requestID = failure.details?.requestID ?? failure.details?.clientRequestID
        let requestLabel = failure.details?.requestID == nil ? "Client request ID" : "Request ID"

        return VStack(alignment: .leading, spacing: 9) {
            Label(failure.title, systemImage: providerFailureIcon(failure.kind))
                .font(.system(size: 13 * chatScale, weight: .semibold))
                .foregroundStyle(.primary)

            Text(failure.userFacingMessage)
                .font(.system(size: 12 * chatScale))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            if let capacity = failure.modelCapacityPresentation {
                Text(verbatim: capacity.guidance)
                    .font(.system(size: 12 * chatScale, weight: .medium))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            if let recovery = failure.conversationRecoveryPresentation {
                Text(recovery.guidance)
                    .font(.system(size: 12 * chatScale, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            if let compactionFailure {
                VStack(alignment: .leading, spacing: 3) {
                    Label("Earlier messages couldn’t be summarized",
                          systemImage: "arrow.trianglehead.2.clockwise.rotate.90")
                        .font(.system(size: 11 * chatScale, weight: .semibold))
                    Text(compactionFailure.message)
                        .font(.system(size: 11 * chatScale))
                    if let diagnostic = compactionFailure.diagnostic {
                        Text("Code: \(diagnostic)")
                            .font(.system(size: 9.5 * chatScale, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .textSelection(.enabled)
                    }
                }
                .foregroundStyle(.secondary)
            }

            if failure.kind != .contextLimit,
               accounts.requiresReconnect(failure.access), !failure.requiresReconnect,
               failure.access == .claudeVertex {
                Text("Your Google account also requires reauthentication.")
                    .font(.system(size: 12 * chatScale, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            if let reset = failure.details?.resetsAt {
                Text("Available again after \(reset.formatted(date: .abbreviated, time: .shortened)).")
                    .font(.system(size: 12 * chatScale, weight: .medium))
                    .foregroundStyle(.secondary)
            } else if let seconds = failure.details?.retryAfterSeconds {
                Text("Provider retry window: \(providerRetryDelay(seconds)).")
                    .font(.system(size: 12 * chatScale, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            if let diagnostic = failure.diagnosticSummary {
                Text(diagnostic)
                    .font(.system(size: 10 * chatScale, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            }

            if let requestID {
                HStack(spacing: 7) {
                    Text("\(requestLabel): \(requestID)")
                        .font(.system(size: 10 * chatScale, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Button { copy(requestID) } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.plain)
                    .help("Copy \(requestLabel.lowercased())")
                }
            }

            providerFailureActions(
                failure,
                failureEntry: entry,
                retryPrompt: retryPrompt,
                accountRequiresReconnect: accounts.requiresReconnect(failure.access))
                .font(.system(size: 11 * chatScale, weight: .medium))
                .buttonStyle(.plain)
                .foregroundStyle(Color.nInfoText)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.nSurface))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .stroke(providerFailureTint(failure.kind).opacity(0.5), lineWidth: 1))
        .accessibilityElement(children: .contain)
    }

    /// Keep every action label intact at the minimum chat width and large text zoom. The first
    /// candidate is the compact single row; SwiftUI selects the leading-aligned stack whenever the
    /// row's full intrinsic width does not fit.
    private func providerFailureActions(_ failure: ProviderFailure,
                                        failureEntry: TranscriptEntry,
                                        retryPrompt: String?,
                                        accountRequiresReconnect: Bool) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) {
                providerFailureActionItems(
                    failure,
                    failureEntry: failureEntry,
                    retryPrompt: retryPrompt,
                    accountRequiresReconnect: accountRequiresReconnect)
            }
            VStack(alignment: .leading, spacing: 8) {
                providerFailureActionItems(
                    failure,
                    failureEntry: failureEntry,
                    retryPrompt: retryPrompt,
                    accountRequiresReconnect: accountRequiresReconnect)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func providerFailureActionItems(_ failure: ProviderFailure,
                                            failureEntry: TranscriptEntry,
                                            retryPrompt: String?,
                                            accountRequiresReconnect: Bool) -> some View {
        let canEditPrompt = bridge.canEditContextLimitPrompt(failureEntry)
        let canStartFresh = bridge.canStartFreshConversation(recovering: failureEntry)
        let recoveryPrompt = bridge.contextLimitRecoveryPrompt(failureEntry)
        if let recovery = failure.conversationRecoveryPresentation,
           canEditPrompt {
            Button {
                guard let prompt = bridge.prepareContextLimitPromptForEditing(
                    failureEntry
                ) else { return }
                draft.text = prompt
                draft.resetHeight(fontSize: 13 * chatScale)
                bridge.focusComposer()
            } label: {
                Label(recovery.editLabel, systemImage: "pencil")
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .buttonStyle(PillButtonStyle(kind: .accent))
            .help(recovery.editHelp)
        }
        if let recovery = failure.conversationRecoveryPresentation,
           canStartFresh {
            Button {
                bridge.startFreshConversation(recovering: failureEntry)
            } label: {
                Label(
                    recoveryPrompt == nil
                        ? recovery.startFreshEmptyLabel
                        : recovery.startFreshLabel,
                    systemImage: "plus.bubble")
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .buttonStyle(PillButtonStyle(kind: canEditPrompt ? .neutral : .accent))
            .help(
                recoveryPrompt == nil
                    ? recovery.startFreshEmptyHelp
                    : recovery.startFreshHelp)
        }
        let recoveryPresentation = failure.accountRecoveryPresentation(
            accountRequiresReconnect: accountRequiresReconnect,
            automaticActionLabel: accounts.subscriptionConnectionAction(
                for: failure.access)?.label)
        if let recoveryPresentation {
            Button {
                // A forced action promises a fresh provider login. Do not route it through the
                // generic Connect policy: an inconclusive credential probe or a persisted RAPT
                // failure can coexist with a daemon that still reports its on-disk credential as
                // logged in, causing Connect to accept that credential without opening sign-in.
                switch recoveryPresentation.action {
                case .forceReconnect:
                    bridge.reconnectAccount(failure.access)
                case .automatic:
                    bridge.connectOrReconnectAccount(failure.access)
                }
            } label: {
                Label(
                    recoveryPresentation.label,
                    systemImage: "person.crop.circle.badge.plus")
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .buttonStyle(PillButtonStyle(kind: .accent))
            .help(recoveryPresentation.help)
        }
        ForEach(failure.resourceLinks) { resource in
            Link(destination: resource.url) {
                Label(resource.label, systemImage: resource.systemImage)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        if let command = failure.diagnosticCommand {
            Button { copy(command) } label: {
                Label("Copy \(command)", systemImage: "doc.on.doc")
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .help("Copy \(command) to inspect provider usage")
        }
        if failure.isResumedNoOutputFailure,
           bridge.canRetryProviderFailureInFreshSession(failureEntry) {
            Button {
                bridge.retryProviderFailureInFreshSession(failureEntry)
            } label: {
                Label("Retry Fresh", systemImage: "arrow.trianglehead.2.clockwise.rotate.90")
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .help("Re-run the prompt in a fresh provider session with bounded history")
        } else if !failure.isResumedNoOutputFailure,
                  let retryPrompt, !retryPrompt.isEmpty {
            Button { bridge.send(retryPrompt) } label: {
                Label("Retry", systemImage: "arrow.clockwise")
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .help("Re-run the prompt that failed")
        }
    }

    private func providerFailureIcon(_ kind: ProviderFailure.Kind) -> String {
        switch kind {
        case .authentication: return "person.crop.circle.badge.exclamationmark"
        case .quota, .rateLimit: return "gauge.with.dots.needle.67percent"
        case .modelAccess: return "cpu.fill"
        case .contextLimit: return "text.badge.exclamationmark"
        case .outputLimit: return "text.badge.exclamationmark"
        case .server: return "server.rack"
        case .network: return "network.slash"
        case .invalidRequest: return "exclamationmark.bubble"
        case .unknown: return "exclamationmark.triangle"
        }
    }

    private func providerFailureTint(_ kind: ProviderFailure.Kind) -> Color {
        switch kind {
        case .server, .network, .unknown: return .nErrorText
        case .authentication, .quota, .rateLimit, .modelAccess, .contextLimit, .outputLimit,
             .invalidRequest:
            return .nWarningText
        }
    }

    private func providerRetryDelay(_ seconds: Double) -> String {
        let count: Int
        let unit: String
        if seconds < 60 {
            count = max(1, Int(ceil(seconds))); unit = "second"
        } else if seconds < 3_600 {
            count = max(1, Int(ceil(seconds / 60))); unit = "minute"
        } else {
            count = max(1, Int(ceil(seconds / 3_600))); unit = "hour"
        }
        return "about \(count) \(unit)\(count == 1 ? "" : "s")"
    }

    /// Most of the allowance is gone, and things have quietly started changing.
    ///
    /// DELIBERATELY NOT AN ERROR. Nothing is broken and nothing is blocked: every request still
    /// succeeds in this state, so the weight of `usageLimitRow` would be a lie. It is the quietest
    /// row in the transcript and it says the one thing a person cannot find out any other way.
    ///
    /// The suggestions line is the reason this exists. Claude skips generating follow-up prompt
    /// suggestions whenever the usage status is anything other than `allowed`, so they vanish at a
    /// threshold with no message and no setting — reported here as a bug twice, and blamed on the
    /// SDK twice before the account's own usage turned out to be it.
    /// A remembered policy the app said into a running turn.
    ///
    /// Left aligned and full width, in the same surface, radius, padding and tinted border as the
    /// other app-authored notice cards, so it reads as Mechanician speaking rather than as the
    /// person. The attribution prefix is stripped for display because the header already says it.
    /// Injected guidance carried its own attribution prefix so authorship survived in the words
    /// themselves, not only in the row that renders them. The card strips it for display because the
    /// header already says it. Returns the text unchanged when the prefix is absent, so this can
    /// never silently eat the first words of something it did not write.
    private static func injectedGuidanceBody(_ guidance: String) -> String {
        let prefix = "Mechanician memory:"
        let trimmed = guidance.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(prefix) else { return trimmed }
        return trimmed.dropFirst(prefix.count).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func memoryPolicyRow(_ entry: TranscriptEntry) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                Image(systemName: "brain")
                    .font(.system(size: 11 * chatScale))
                    .foregroundStyle(.secondary)
                Text("From your memory")
                    .font(.system(size: 12 * chatScale, weight: .medium))
                    .foregroundStyle(.primary)
            }
            Text(Self.injectedGuidanceBody(entry.text))
                .font(.system(size: 11 * chatScale))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.nSurface))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .strokeBorder(Color.nInfoText.opacity(0.28)))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "From your memory. \(Self.injectedGuidanceBody(entry.text))")
    }

    private func usageWarningRow(_ warning: UsageWarning) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                Image(systemName: "gauge.with.needle")
                    .font(.system(size: 11 * chatScale))
                    .foregroundStyle(.secondary)
                (warning.percentUsed.map { percent in
                    Text("\(warning.title) (\(percent)%)")
                } ?? Text(verbatim: warning.title))
                    .font(.system(size: 12 * chatScale, weight: .medium))
                    .foregroundStyle(.primary)
            }
            if let reset = warning.resetsAt {
                Text("Resets \(reset.formatted(date: .abbreviated, time: .shortened)). Nothing is blocked until then.")
                    .font(.system(size: 11 * chatScale))
                    .foregroundStyle(.secondary)
            } else {
                Text("Nothing is blocked until the allowance resets.")
                    .font(.system(size: 11 * chatScale))
                    .foregroundStyle(.secondary)
            }
            Text("Claude also stops offering follow-up prompt suggestions while usage is over this threshold.")
                .font(.system(size: 11 * chatScale))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.nSurface))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .strokeBorder(Color.nInfoText.opacity(0.28)))
        .accessibilityElement(children: .combine)
    }

    private func usageLimitRow(_ entry: TranscriptEntry, limit: UsageLimitError) -> some View {
        let rawMessage = entry.text.lowercased().hasPrefix("error: ")
            ? String(entry.text.dropFirst(7)) : entry.text
        return VStack(alignment: .leading, spacing: 9) {
            Label(limit.title, systemImage: "clock.badge.exclamationmark")
                .font(.system(size: 13 * chatScale, weight: .semibold))
                .foregroundStyle(.primary)

            if let reset = limit.resetsAt {
                Text("Resets \(reset.formatted(date: .abbreviated, time: .shortened)).")
                    .font(.system(size: 12 * chatScale, weight: .medium))
                    .foregroundStyle(.secondary)
            } else if !rawMessage.isEmpty {
                // Legacy saved errors still carry Anthropic's reset wording even though they predate
                // the structured `resetsAt` field.
                Text(rawMessage)
                    .font(.system(size: 12 * chatScale))
                    .foregroundStyle(.secondary)
            }

            Text(limit.creditsExhausted
                 ? "Claude also reports that your usage-credit balance is exhausted."
                 : "Your included Claude plan allowance is exhausted. This does not necessarily mean your usage-credit balance is empty.")
                .font(.system(size: 12 * chatScale))
                .foregroundStyle(.secondary)

            HStack(spacing: 14) {
                Link(destination: URL(string: "https://claude.ai/settings/usage")!) {
                    Label("View Claude usage", systemImage: "arrow.up.right.square")
                }
                Button {
                    copy("/status")
                } label: {
                    Label("Copy /status", systemImage: "doc.on.doc")
                }
                .help("Run /status in Claude Code to inspect plan usage")
            }
            .font(.system(size: 11 * chatScale, weight: .medium))
            .buttonStyle(.plain)
            .foregroundStyle(Color.nInfoText)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.nSurface))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.orange.opacity(0.45), lineWidth: 1))
        .accessibilityElement(children: .contain)
    }

    /// A safety refusal, told truthfully (O5-008).
    ///
    /// Deliberately NOT styled as an error: nothing is broken, the account is fine, and on the
    /// fallback path the turn actually succeeded. The visual weight belongs on the attribution —
    /// which model declined and which one answered — because the user chose a specific model and the
    /// transcript now contains text from a different one.
    private func refusalRow(_ refusal: ClaudeRefusalRecord) -> some View {
        let replaced = refusal.outcome == .fallback && refusal.fallbackModel != nil
        return VStack(alignment: .leading, spacing: 8) {
            Label(
                replaced ? "Answered by a different model" : "Request declined",
                systemImage: replaced ? "arrow.triangle.branch" : "hand.raised")
                .font(.system(size: 13 * chatScale, weight: .semibold))
                .foregroundStyle(.primary)

            Text(refusal.headline)
                .font(.system(size: 12 * chatScale))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            if let explanation = refusal.explanation, !explanation.isEmpty {
                // Shown verbatim and never parsed — the app has no opinion about this wording, and
                // the user is entitled to read why they were declined.
                Text(explanation)
                    .font(.system(size: 12 * chatScale))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            if let category = refusal.category, !category.isEmpty {
                Text(category.uppercased())
                    .font(.system(size: 10 * chatScale, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.nSurface))
                    .overlay(Capsule().stroke(Color.secondary.opacity(0.3), lineWidth: 1))
                    .accessibilityLabel("Refusal category: \(category)")
            }

            if replaced, refusal.persistent {
                Text("This model answers the rest of this session unless you change it.")
                    .font(.system(size: 11 * chatScale))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.nSurface))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.35), lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(refusal.headline)
    }

    @ViewBuilder
    private func questionRow(_ entry: TranscriptEntry) -> some View {
        if let reqId = entry.questionId, let questions = entry.questions, !questions.isEmpty {
            if entry.questionDecided == true {
                answeredQuestionSummary(
                    questions,
                    answers: entry.questionAnswers ?? [:],
                    freeTextResponse: entry.questionFreeTextResponse)
            } else if bridge.canRespondQuestion(reqId) {
                QuestionCard(
                    questions: questions,
                    scale: chatScale,
                    isSubmitting: bridge.questionResponsePending(reqId),
                    error: bridge.questionResponseError(reqId)
                ) { answers, other in
                    bridge.respondQuestion(reqId, answers: answers, response: other)
                }
            } else {
                // Turn ended before an answer (e.g. interrupted) — nothing to answer now.
                answeredQuestionSummary(
                    questions,
                    answers: entry.questionAnswers ?? [:],
                    freeTextResponse: entry.questionFreeTextResponse,
                    note: bridge.questionResponseError(reqId)
                        ?? interactionClosureNote(entry.interactionClosure)
                        ?? interactionResponseNote(entry.interactionResponseStatus)
                        ?? "No longer waiting for an answer.")
            }
        }
    }

    /// Static recap shown once a question has been answered (or is no longer active).
    private func answeredQuestionSummary(_ questions: [AskQuestion],
                                         answers: [String: String],
                                         freeTextResponse: String? = nil,
                                         note: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(questions.enumerated()), id: \.offset) { _, q in
                VStack(alignment: .leading, spacing: 2) {
                    Text(q.question).font(.system(size: 12 * chatScale, weight: .medium))
                    Text(answers[q.question].map { $0.isEmpty ? "—" : $0 } ?? "—")
                        .font(.system(size: 12 * chatScale)).foregroundStyle(Color.nInfoText)
                }
            }
            if let freeTextResponse, !freeTextResponse.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("ADDITIONAL RESPONSE")
                        .font(.system(size: 9 * chatScale, weight: .semibold))
                        .foregroundStyle(.tertiary)
                    Text(freeTextResponse)
                        .font(.system(size: 12 * chatScale))
                        .foregroundStyle(Color.nInfoText)
                }
            }
            if let note { Text(note).font(.system(size: 11 * chatScale)).foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.nSurface))
    }

    private func interactionClosureNote(_ closure: InteractionClosure?) -> String? {
        guard let closure else { return nil }
        switch closure.reason {
        case "turn_interrupted": return "Cancelled because the turn was stopped."
        case "runtime_stopped": return "Closed because the provider stopped."
        case "runtime_failed": return "Closed because the provider failed."
        default: return "Closed before a response was accepted."
        }
    }

    private func interactionClosureLabel(_ closure: InteractionClosure?) -> String {
        closure?.outcome == "cancelled" ? "Cancelled" : "No longer waiting"
    }

    private func interactionResponseNote(_ status: InteractionResponseStatus?) -> String? {
        switch status {
        case .selected:
            return "The response was saved, but provider acknowledgement was not observed."
        case .rejected:
            return "The saved response was not accepted by the provider."
        case .acknowledgementMismatch:
            return "The provider acknowledgement did not match the saved response."
        case .unknown:
            return "This response has lifecycle detail recorded by a newer Mechanician version."
        case .accepted, .none:
            return nil
        }
    }

    private func inactiveInteractionLabel(_ entry: TranscriptEntry) -> String {
        if entry.interactionClosure != nil {
            return interactionClosureLabel(entry.interactionClosure)
        }
        switch entry.interactionResponseStatus {
        case .selected: return "Saved, not confirmed"
        case .rejected: return "Not accepted"
        case .acknowledgementMismatch: return "Confirmation mismatch"
        case .unknown: return "Response recorded"
        case .accepted, .none: return "No longer waiting"
        }
    }

    /// VoiceOver description of a tool call — its name, status, and input summary.
    private func toolAccessibilityLabel(_ entry: TranscriptEntry) -> String {
        let name = entry.toolName ?? "tool"
        let status: String
        if entry.toolRefused == true {
            // Announcing "error" for a call the person declined tells a VoiceOver user something
            // broke, and gives them no way to find out that nothing did.
            status = "denied"
        } else {
            switch entry.resolvedToolState {
            case .running: status = "running"
            case .succeeded: status = "complete"
            case .failed: status = "error"
            case .stopped: status = "stopped"
            }
        }
        return supersededActionAccessibilityLabel(
            "\(name) tool, \(status). \(entry.text)",
            isSuperseded: entry.isSuperseded)
    }

    private var supersededToolBadge: some View {
        Text("Superseded")
            .font(.system(size: 9.5 * chatScale, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.secondary.opacity(0.12)))
            .overlay(Capsule().stroke(Color.secondary.opacity(0.25), lineWidth: 0.5))
            .accessibilityLabel(
                "Superseded. Retained as audit evidence because this action may already have run.")
    }

    @ViewBuilder
    private func toolRow(_ entry: TranscriptEntry) -> some View {
        if entry.toolName == "Workflow" {
            // A workflow renders as a rich, live-updating run card, not a generic tool.
            VStack(alignment: .leading, spacing: 6) {
                if entry.isSuperseded { supersededToolBadge }
                WorkflowCard(toolUseId: entry.toolUseId)
            }
        } else {
            genericToolRow(entry)
        }
    }

    @ViewBuilder
    private func genericToolRow(_ entry: TranscriptEntry) -> some View {
        let expanded = bridge.expandedTools.contains(entry.id)
        // A generated image is primary transcript content, not an optional diagnostic. Keep its
        // standalone card expanded on restore as well as during the live turn.
        let hasInlineImage = entry.toolImage != nil || bridge.toolImages[entry.id] != nil
        let showsDetail = expanded || hasInlineImage
        VStack(alignment: .leading, spacing: 0) {
            Button {
                if bridge.expandedTools.contains(entry.id) { bridge.expandedTools.remove(entry.id) }
                else { bridge.expandedTools.insert(entry.id) }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: entry.resolvedToolState == .running ? "hourglass"
                        : entry.resolvedToolState == .stopped ? "stop.circle" : "wrench.and.screwdriver")
                        .foregroundStyle(entry.toolIsError ? Color.nErrorText : Color.secondary)
                    Text(entry.toolName ?? "tool").bold()
                    Text(AgentBridge.toolTitle(name: entry.toolName ?? "tool", rawInput: entry.text))
                        .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    if entry.isSuperseded { supersededToolBadge }
                    Spacer()
                    Image(systemName: showsDetail ? "chevron.down" : "chevron.right")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .font(.system(size: 12 * chatScale, design: .monospaced))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(8)
            .accessibilityLabel(toolAccessibilityLabel(entry))
            .accessibilityHint(hasInlineImage
                ? "The generated image is shown inline."
                : (expanded
                ? (entry.resolvedToolState == .running
                    ? "Showing live input and changes while running. Activate to collapse."
                    : "Showing result. Activate to collapse.")
                : (entry.resolvedToolState == .running
                    ? "Running. Activate to show live input and changes."
                    : "Activate to show the result.")))

            if showsDetail {
                ExpandedToolContent(
                    entry: entry,
                    capturedImage: bridge.toolImages[entry.id],
                    persistedImageURL: bridge.persistedToolImageURL(for: entry),
                    chatScale: chatScale)
                    .equatable()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.nSurface))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.nMuted.opacity(0.4)))
    }

    @ViewBuilder
    private func permissionRow(_ entry: TranscriptEntry) -> some View {
        let tool = entry.permName ?? "tool"
        if tool == "ExitPlanMode" {
            planRow(entry)
        } else {
            genericPermissionRow(entry, tool: tool)
        }
    }

    /// Plan mode: render the agent's plan (markdown) with an approve/keep-planning choice.
    @ViewBuilder
    private func planRow(_ entry: TranscriptEntry) -> some View {
        let canRespond = entry.permissionId.map(bridge.canRespondPermission) == true
        let pending = entry.permissionId.map(bridge.permissionResponsePending) == true
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "list.bullet.clipboard.fill").foregroundStyle(Color.nInfoText)
                Text("Plan").font(.system(size: 13 * chatScale, weight: .semibold))
                Spacer()
                if entry.permDecided {
                    Text(entry.permAllowed ? "Approved" : "Kept planning")
                        .font(.system(size: 11 * chatScale)).foregroundStyle(.secondary)
                } else if pending {
                    HStack(spacing: 5) {
                        OrbitingDots(diameter: 11)
                        Text("Sending response…")
                    }
                    .font(.system(size: 11 * chatScale)).foregroundStyle(.secondary)
                } else if !canRespond {
                    Text(inactiveInteractionLabel(entry))
                        .font(.system(size: 11 * chatScale)).foregroundStyle(.secondary)
                }
            }
            MarkdownText(text: entry.text, scale: chatScale)
                .textSelection(.enabled)
            if let pid = entry.permissionId,
               let error = bridge.permissionResponseError(pid) {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11 * chatScale))
                    .foregroundStyle(Color.nWarningText)
            } else if !entry.permDecided, !canRespond,
                      let note = interactionClosureNote(entry.interactionClosure)
                        ?? interactionResponseNote(entry.interactionResponseStatus) {
                Text(note)
                    .font(.system(size: 11 * chatScale))
                    .foregroundStyle(.secondary)
            }
            if !entry.permDecided, canRespond, !pending, let pid = entry.permissionId {
                HStack(spacing: 8) {
                    Spacer()
                    Button("Keep planning") { bridge.respondPermission(pid, allow: false) }
                        .buttonStyle(PillButtonStyle(kind: .plain))
                    Button("Approve & proceed") { bridge.approvePlan(pid) }
                        .buttonStyle(PillButtonStyle(kind: .accent))
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.nSurface))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.nAccent.opacity(0.45)))
    }

    @ViewBuilder
    private func genericPermissionRow(_ entry: TranscriptEntry, tool: String) -> some View {
        let canRespond = entry.permissionId.map(bridge.canRespondPermission) == true
        let pending = entry.permissionId.map(bridge.permissionResponsePending) == true
        let presentation = PermissionPresentation.request(
            tool: tool,
            payload: entry.text,
            writeEscape: entry.permWriteEscapeTarget.map {
                PermissionWriteEscape(target: $0, workspace: entry.permWriteEscapeWorkspace)
            },
            decision: entry.permDecided
                ? (entry.permAllowed ? .allowed : .denied)
                : .pending)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 14 * chatScale, weight: .semibold))
                    .foregroundStyle(Color.nWarningText)
                    .frame(width: 18 * chatScale)
                VStack(alignment: .leading, spacing: 3) {
                    Text(presentation.title)
                        .font(.system(size: 14 * chatScale, weight: .semibold))
                    Text(presentation.summary)
                        .font(.system(size: 11.5 * chatScale))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if entry.permDecided {
                    Text(entry.permAllowed
                         ? (entry.permAlways == true ? "Always allowed" : "Allowed")
                         : "Denied")
                        .font(.system(size: 11 * chatScale, weight: .medium))
                        .foregroundStyle(.secondary)
                        .fixedSize()
                } else if pending {
                    HStack(spacing: 5) {
                        OrbitingDots(diameter: 11)
                        Text("Sending approval…")
                    }
                    .font(.system(size: 11 * chatScale, weight: .medium))
                    .foregroundStyle(.secondary)
                    .fixedSize()
                } else if !canRespond {
                    Text(inactiveInteractionLabel(entry))
                        .font(.system(size: 11 * chatScale)).foregroundStyle(.secondary)
                        .fixedSize()
                }
            }
            if !presentation.details.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(presentation.details) { detail in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(detail.label.uppercased())
                                .font(.system(size: 9 * chatScale, weight: .semibold))
                                .foregroundStyle(.tertiary)
                            Text(detail.value)
                                .font(.system(
                                    size: 11 * chatScale,
                                    design: detail.monospaced ? .monospaced : .default))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                    }
                }
                .padding(9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.nBg.opacity(0.55)))
            }
            if let pid = entry.permissionId,
               let error = bridge.permissionResponseError(pid) {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11 * chatScale))
                    .foregroundStyle(Color.nWarningText)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !entry.permDecided, !canRespond,
                      let note = interactionClosureNote(entry.interactionClosure)
                        ?? interactionResponseNote(entry.interactionResponseStatus) {
                Text(note)
                    .font(.system(size: 11 * chatScale))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !entry.permDecided, canRespond, !pending, let pid = entry.permissionId {
                HStack(spacing: 8) {
                    Spacer()
                    Button("Deny") { bridge.respondPermission(pid, allow: false) }
                        .buttonStyle(PillButtonStyle(kind: .plain))
                    Button("Always allow") { bridge.respondPermission(pid, allow: true, always: true) }
                        .buttonStyle(PillButtonStyle(kind: .neutral))
                    Button("Allow once") { bridge.respondPermission(pid, allow: true) }
                        .buttonStyle(PillButtonStyle(kind: .accent))
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.nSurface))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.orange.opacity(0.42)))
    }

    private var composer: some View {
        VStack(spacing: 6) {
            composerBanners
            ComposerCard(
                bridge: bridge,
                presentation: ComposerPresentationState(bridge: bridge),
                draft: draft,
                dictation: dictation,
                chatScale: chatScale,
                onSubmit: submit)
                .equatable()
                .guidedHelpTarget(.conversationComposer, registry: guideRegistry)
        }
        .padding(12)
        // Any queue mutation — a newly submitted message, a removed row (×), or a dispatched prompt
        // — can leave the inline-edit index pointing at a DIFFERENT row (the ForEach is keyed by
        // index). Cancel any in-progress edit so its stale text can't overwrite the new message.
        .onChange(of: bridge.queuedPrompts) { _, _ in
            if editingQueueIndex != nil { editingQueueIndex = nil; editingQueueText = "" }
        }
    }

    /// Resume-after-interject chip, queued prompts, and the running hint.
    @ViewBuilder
    private var composerBanners: some View {
        if let request = bridge.currentProviderAccessRequest {
            ProviderAccessRequestCard(bridge: bridge, request: request)
        }
        if let change = bridge.pendingSettingChange {
            MechanicianSettingChangeCard(bridge: bridge, request: change)
        }
        if ProviderSetupBannerPolicy.shouldShow(
            needsProviderSetup: bridge.needsProviderSetup,
            currentAccess: bridge.currentModelAccess,
            request: bridge.currentProviderAccessRequest
        ) {
            let access = bridge.currentModelAccess
            let recoveryAccess = bridge.pendingProviderSetupRecoveryDestination ?? access
            ProviderSetupBanner(
                access: access,
                requiresReconnect: accounts.requiresReconnect(access),
                progressLabel: bridge.pendingProviderSetupRecoveryProgressLabel,
                error: accounts.error(for: recoveryAccess)
                    ?? bridge.pendingProviderSetupRecoveryError,
                actionLabel: accounts.subscriptionConnectionLabel(for: access)
                    ?? "Choose Connection…"
            ) {
                bridge.beginProviderSetupRecovery()
                if access.usesInteractiveAccountFlow {
                    bridge.connectOrReconnectAccount(access)
                } else {
                    showProviders(using: openWindow)
                }
            }
        }
        if bridge.currentTurnAppearsStalled {
            HStack(spacing: 7) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption2)
                VStack(alignment: .leading, spacing: 1) {
                    Text("This turn appears stalled").fontWeight(.semibold)
                    Text("Stop will recover the provider lane if it does not respond.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Stop and recover") { bridge.interrupt() }
                    .buttonStyle(.plain)
                    .font(.caption.weight(.semibold))
            }
            .font(.caption)
            .foregroundStyle(Color.nWarningText)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
            .accessibilityElement(children: .combine)
        }
        if bridge.currentQueueIsPaused, !bridge.queuedPrompts.isEmpty {
            HStack(spacing: 7) {
                Image(systemName: "pause.circle.fill").font(.caption2)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Recovered queued work is paused").fontWeight(.semibold)
                    Text("Review the messages below before allowing them to run.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Resume queue") { bridge.resumeCurrentQueue() }
                    .buttonStyle(.plain)
                    .font(.caption.weight(.semibold))
            }
            .font(.caption)
            .foregroundStyle(Color.nWarningText)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
            .accessibilityElement(children: .combine)
        }
        // Wait-mode: this conversation is parked waiting for an event and will auto-resume when the
        // trigger fires. Resume it now, or cancel the wait.
        if let trig = bridge.currentConversation?.armedTrigger, !bridge.isStreaming {
            HStack(spacing: 6) {
                Image(systemName: "hourglass").font(.caption2)
                Text("Waiting \(trig.summary). I'll resume automatically").lineLimit(1)
                Spacer()
                Button("Resume now") { if let id = bridge.currentID { bridge.resumeWaitNow(id) } }
                    .buttonStyle(.plain).font(.caption2.weight(.semibold))
                Button { if let id = bridge.currentID { bridge.cancelWait(id) } } label: {
                    Image(systemName: "xmark.circle.fill").font(.caption2)
                }
                .buttonStyle(.plain).help("Cancel the wait")
                .accessibilityLabel("Cancel wait")
            }
            .font(.caption).foregroundStyle(Color.nWarningText)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
        }
        // Dictation failures used to be silent ("asked for permission but nothing happened") —
        // surface them so it's clear what to fix.
        if let err = dictation.errorMessage {
            HStack(spacing: 6) {
                Image(systemName: "mic.slash").font(.caption2)
                Text(err).lineLimit(2)
                Spacer()
                Button { dictation.errorMessage = nil } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .help("Dismiss error")
                    .accessibilityLabel("Dismiss error")
            }
            .font(.caption).foregroundStyle(Color.nWarningText)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
        }
        if let resume = bridge.pendingResume, !bridge.isStreaming {
            // Tap the chip to resume; the trailing × dismisses it (a manual interject never
            // auto-clears pendingResume, so without this the chip would sit forever).
            HStack(spacing: 6) {
                Button { bridge.resume() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.uturn.left").font(.caption2)
                        Text("Resume: \(resume)").lineLimit(1)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Re-run the prompt that was interrupted")
                Button { bridge.cancelResume() } label: {
                    Image(systemName: "xmark.circle.fill").font(.caption2)
                }
                .buttonStyle(.plain)
                .help("Dismiss without resuming")
                .accessibilityLabel("Dismiss")
            }
            .font(.caption).foregroundStyle(Color.nInfoText)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.nAccent.opacity(0.12)))
        }
        if !bridge.queuedPrompts.isEmpty {
            VStack(spacing: 3) {
                ForEach(Array(bridge.queuedPrompts.enumerated()), id: \.offset) { i, p in
                    HStack(spacing: 6) {
                        ComposerRoadSign(kind: .yield, size: 13, raised: false)
                            .frame(width: 14, height: 14)
                        if editingQueueIndex == i {
                            TextField("", text: $editingQueueText)
                                .textFieldStyle(.plain)
                                .font(.caption)
                                .focused($queueEditFocused)
                                .onSubmit { commitQueueEdit() }
                                .onExitCommand { editingQueueIndex = nil } // Esc cancels
                            Button { commitQueueEdit() } label: { Image(systemName: "checkmark").font(.caption2) }
                                .buttonStyle(.plain).foregroundStyle(Color.nInfoText).help("Save")
                                .accessibilityLabel("Save edit")
                        } else {
                            Text(p).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            Spacer()
                            let expectedQueue = bridge.queuedPrompts
                            Button {
                                bridge.redirectQueued(at: i, expectedQueue: expectedQueue)
                            } label: {
                                ComposerRoadSign(kind: .detour, size: 12, raised: false)
                                    .frame(width: 16, height: 16)
                            }
                            .buttonStyle(.plain)
                            .help("Stop current turn and run this prompt now")
                            .accessibilityLabel("Stop and redirect with queued prompt")
                            Button { startQueueEdit(i, p) } label: { Image(systemName: "pencil").font(.caption2) }
                                .buttonStyle(.plain).foregroundStyle(.secondary).help("Edit")
                                .accessibilityLabel("Edit queued prompt")
                        }
                        Button { bridge.removeQueued(at: i) } label: { Image(systemName: "xmark").font(.caption2) }
                            .buttonStyle(.plain).foregroundStyle(.secondary).help("Remove")
                            .accessibilityLabel("Remove from queue")
                    }
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Color.nSurface))
                }
            }
        }
        // Live turn/delegate status lives in the fixed-height status bar. Keeping a duplicate hint
        // here used to add and remove a composer row at terminal state, visibly shifting every
        // transcript message even when no transcript geometry changed.
    }

    private func startQueueEdit(_ index: Int, _ text: String) {
        editingQueueText = text
        editingQueueIndex = index
        DispatchQueue.main.async { queueEditFocused = true }
    }

    /// Commit an inline queue edit; an emptied prompt removes the row.
    private func commitQueueEdit() {
        if let i = editingQueueIndex {
            let t = editingQueueText.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty { bridge.removeQueued(at: i) } else { bridge.updateQueued(at: i, t) }
        }
        editingQueueIndex = nil
    }

    private var deliveryPolicy: ComposerDeliveryPolicy {
        ComposerDeliveryPolicy(
            hasText: ChatInput.hasSubmittableText(draft.text),
            runtimeReady: bridge.composerAcceptsSubmission,
            turnReserved: bridge.currentConversationHasReservedTurn,
            canGuide: bridge.guidanceIsDefaultForCurrentTurn,
            providerAccessPending: bridge.currentProviderAccessRequest != nil,
            providerSetupRequired: bridge.needsProviderSetup)
    }

    private func submit(_ requestedAction: ComposerDeliveryAction) {
        guard deliveryPolicy.canSubmit else { return }
        editingQueueIndex = nil   // cancel any dangling inline queue edit so its stale index can't
                                  // rebind to this newly-queued message (old-reappears/new-lost bug)
        // Turn ownership can change between drawing the control and invoking it. Resolve the chosen
        // mode against the latest state so a terminal race starts a normal turn and lost guidance
        // capability safely becomes Send next.
        // An armed skill is prompt construction, not a protocol feature: the message uses the
        // provider's own invocation (`/name` for Claude, `$name` for Codex). One-shot, like an
        // attachment — it is consumed here whichever delivery mode is used.
        let text = withArmedSkill(draft.text)
        bridge.armedSkill = nil
        switch deliveryPolicy.resolvedAction(selecting: requestedAction) {
        case .guideCurrentTurn:
            bridge.guide(text)
        case .sendNext:
            bridge.sendNext(text)
        case .startTurn:
            bridge.send(text)
        case .stopAndRedirect:
            bridge.stopAndRedirect(text)
        }
        clearComposerAfterSend()
    }

    /// Prefix the message with the armed skill's provider-native invocation.
    ///
    /// Deliberately does nothing if the text already begins with a slash: the user typing an
    /// explicit command/skill outranks a pill they may have armed and forgotten.
    private func withArmedSkill(_ text: String) -> String {
        guard let skill = bridge.armedSkill else { return text }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.hasPrefix("/"), !trimmed.hasPrefix("$") else { return text }
        return trimmed.isEmpty ? skill.invocation : "\(skill.invocation) \(trimmed)"
    }

    /// Empty the composer after a submit. If dictation is still live (the mic intentionally keeps
    /// recording), forget what was already submitted so the box stays clear and further speech
    /// starts a fresh transcript — otherwise dictation's onChange would immediately re-fill it.
    private func clearComposerAfterSend() {
        draft.text = ""
        draft.resetHeight(fontSize: 13 * chatScale)
        bridge.setDraft("", for: bridge.currentID)   // the queued draft was just sent — clear its stored copy
        if dictation.isRecording {
            draft.dictationBase = ""
            dictation.reset()
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// A provider context boundary inside the canonical transcript.
///
/// The row distinguishes three different truths that used to collapse into one sentence: the full
/// Mechanician transcript still exists, the provider began using a compacted continuation after
/// this point, and only Claude currently exposes the actual continuity summary. It expands in
/// place so context state remains part of the conversation rather than becoming a separate mode.
private struct CompactionTranscriptRow: View {
    let failed: Bool
    let failureMessage: String?
    let detail: String?
    let summary: String?
    let summarySource: String?
    let summaryTruncated: Bool
    let access: ModelAccess?
    let chatScale: CGFloat

    @State private var expanded = false
    @Environment(\.invalidateTranscriptRowHeight)
    private var invalidateTranscriptRowHeight

    private var providerSummary: String? {
        guard summarySource == "claude_post_compact",
              let summary,
              !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return summary
    }

    /// Keep the collapsed boundary self-contained for VoiceOver. The visible second line already
    /// carries trigger/token detail, but replacing the button's children with an explicit label
    /// would otherwise discard it along with the summary provenance and truncation state.
    private var accessibilityValue: Text {
        var parts: [String] = []
        if let detail { parts.append(detail) }
        if providerSummary != nil {
            parts.append(String(localized: "Claude’s continuity summary available"))
            if summaryTruncated {
                parts.append(String(localized:
                    "The provider summary exceeded the transcript safety limit, so its end is not shown."))
            }
        } else {
            parts.append(String(localized: "Provider summary not exposed"))
        }
        parts.append(expanded
            ? String(localized: "Expanded")
            : String(localized: "Collapsed"))
        return Text(verbatim: parts.joined(separator: ". "))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if expanded, !failed {
                Divider().padding(.horizontal, 11)
                expandedContents
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.nSurface))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .strokeBorder((failed ? Color.nWarningText : Color.nInfoText).opacity(0.32)))
    }

    @ViewBuilder
    private var header: some View {
        if failed {
            headerContents.accessibilityElement(children: .combine)
        } else {
            Button {
                expanded.toggle()
                DispatchQueue.main.async { invalidateTranscriptRowHeight() }
            } label: {
                headerContents
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Summarized earlier messages")
            .accessibilityValue(accessibilityValue)
            .accessibilityHint(expanded
                ? Text("Collapse context details")
                : Text("Expand to inspect context details"))
            .help(expanded ? "Hide context details" : "Show context details")
        }
    }

    private var headerContents: some View {
        HStack(spacing: 9) {
            Image(systemName: "arrow.trianglehead.2.clockwise.rotate.90")
                .foregroundStyle(failed ? Color.nWarningText : Color.nInfoText)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(failed
                     ? "Couldn’t summarize earlier messages"
                     : "Summarized earlier messages")
                    .font(.system(size: 12 * chatScale, weight: .semibold))
                if let failureMessage {
                    Text(verbatim: failureMessage)
                        .font(.system(size: 11 * chatScale))
                        .foregroundStyle(.secondary)
                } else if let detail {
                    Text(verbatim: detail)
                        .font(.system(size: 11 * chatScale))
                        .foregroundStyle(.secondary)
                } else {
                    Text("Earlier messages were summarized so the conversation can keep going.")
                        .font(.system(size: 11 * chatScale))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if !failed {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10 * chatScale, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var expandedContents: some View {
        VStack(alignment: .leading, spacing: 9) {
            if let providerSummary {
                Text("Claude’s continuity summary")
                    .font(.system(size: 10 * chatScale, weight: .semibold))
                    .foregroundStyle(Color.nInfoText)
                Text(verbatim: providerSummary)
                    .font(.system(size: 11 * chatScale))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if summaryTruncated {
                    Text("The provider summary exceeded the transcript safety limit, so its end is not shown.")
                        .font(.system(size: 10 * chatScale))
                        .foregroundStyle(Color.nWarningText)
                }
            } else {
                Text("Provider summary not exposed")
                    .font(.system(size: 10 * chatScale, weight: .semibold))
                    .foregroundStyle(Color.nInfoText)
                if access == .codexSubscription {
                    Text("Codex reported this boundary but does not expose the text of its compacted summary.")
                        .font(.system(size: 11 * chatScale))
                        .foregroundStyle(.secondary)
                } else {
                    Text("The provider did not expose summary text for this boundary.")
                        .font(.system(size: 11 * chatScale))
                        .foregroundStyle(.secondary)
                }
            }
            Divider()
            Text("Mechanician retains the complete transcript above this boundary.")
                .font(.system(size: 10 * chatScale))
                .foregroundStyle(.secondary)
            Text("Messages after this point continue from the provider’s compacted context.")
                .font(.system(size: 10 * chatScale))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 11)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct CopyButton: View {
    let text: String
    var scale: CGFloat = 1
    @State private var copied = false
    @State private var hovering = false

    // FR-99: match NativeAssistantCell.restActionAlpha so both transcript surfaces recede identically.
    private static let restAlpha: CGFloat = 0.4

    var body: some View {
        Button(action: perform) {
            // FR-99: same rest/hover/confirm contract as the agent-output actions
            // (NativeAssistantCell) — faint at rest, only this control brightens on hover, no
            // background fill, green checkmark on click.
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 12.5 * scale, weight: .semibold))
                .frame(width: 22 * scale, height: 20 * scale)
                .foregroundStyle(copied ? Color.nSuccessText : (hovering ? Color.primary : Color.secondary))
                .opacity(copied || hovering ? 1 : CopyButton.restAlpha)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .animation(.easeOut(duration: 0.15), value: copied)
        .help(copied ? "Copied" : "Copy message")
        .accessibilityLabel("Copy message")
        .accessibilityValue(copied ? "Copied" : "Not copied")
    }

    private func perform() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.95) { copied = false }
    }
}

/// The Magic & Lasers beam palette, sampled from magic_and_lasers.PNG's left-hand swirl:
/// violet and gold dominate, with teal and pink shimmer. The dictation waveform retains this softer
/// "magic" side of the mark; the caret, categorical meters, activity outline, and orbiting dots use
/// the separate crisp laser spectrum.
enum MagicBeam {
    static let components: [(r: Double, g: Double, b: Double)] = [
        (0.62, 0.45, 0.95),   // violet
        (1.00, 0.78, 0.42),   // gold
        (0.45, 0.85, 0.90),   // teal
        (0.95, 0.55, 0.80),   // pink
    ]

    /// Raw components sampled at fraction `t` (0…1) across the palette, smoothly interpolated.
    /// AppKit surfaces (the composer caret) need the numbers rather than a SwiftUI `Color`, and
    /// sharing one sampler is what keeps every chromatic surface speaking the same language.
    static func rgb(at t: Double, shift: Double = 0) -> (r: Double, g: Double, b: Double) {
        let n = components.count
        let x = ((t + shift).truncatingRemainder(dividingBy: 1) + 1).truncatingRemainder(dividingBy: 1) * Double(n)
        let i = Int(x) % n, f = x - Double(Int(x))
        let a = components[i], b = components[(i + 1) % n]
        return (a.r + (b.r - a.r) * f, a.g + (b.g - a.g) * f, a.b + (b.b - a.b) * f)
    }

    /// A color sampled at fraction `t` (0…1) across the palette, smoothly interpolated — for a
    /// flowing spectrum across the voice waveform, etc. `shift` rotates the spectrum (animate it
    /// to make the colors drift).
    static func color(at t: Double, shift: Double = 0) -> Color {
        let c = rgb(at: t, shift: shift)
        return Color(red: c.r, green: c.g, blue: c.b)
    }
}

/// Stop is a quiet, flat action glyph. Activity belongs to the composer as a whole and is shown by
/// its breathing chromatic outline instead of a button-local ring.
struct StopButton: View {
    let action: () -> Void
    var helpText = "Stop (⌘.)"
    var accessibilityText = "Stop"
    var accessibilityHintText = "Stops the agent"
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            ComposerRoadSign(kind: .stop, size: 23, highlighted: hovering, raised: false)
            .frame(width: 34, height: 34)
            .contentShape(Circle())
        }
        .buttonStyle(ComposerRoundButtonStyle())
        .onHover { hovering = $0 }
        .help(helpText)
        .accessibilityLabel(accessibilityText)
        .accessibilityHint(accessibilityHintText)
        // ⌘. is owned by the Conversation → Stop Generating menu command (avoids a
        // duplicate-shortcut conflict); this button remains clickable.
    }
}

/// Send and every in-flight action use the same quiet flat sign family. A disabled control retains
/// its selected glyph instead of incorrectly falling back to Send.
struct SendButton: View {
    let enabled: Bool
    let action: () -> Void
    var helpText = "Send"
    var accessibilityText = "Send message"
    var icon: ComposerRoadSignKind = .send
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Group {
                if enabled {
                    armed
                } else {
                    idle
                }
            }
            .frame(width: 34, height: 34)
            .contentShape(Circle())
            .scaleEffect(hovering && enabled ? 1.06 : 1.0)
            .animation(.spring(response: 0.28, dampingFraction: 0.6), value: hovering)
        }
        .buttonStyle(ComposerRoundButtonStyle())
        .disabled(!enabled)
        .onHover { hovering = $0 }
        .help(helpText)
        .accessibilityLabel(accessibilityText)
    }

    private var armed: some View {
        ComposerRoadSign(kind: icon, size: 23, highlighted: hovering)
    }

    private var idle: some View {
        ComposerRoadSign(kind: icon, size: 23, raised: false)
            .grayscale(1)
            .opacity(0.34)
    }
}

/// Three dots orbiting a small circle, each gently pulsing in size — a livelier "working"
/// mark than a stock spinner. Core Animation keeps the motion off the SwiftUI render loop.
/// By default the dots use three alternating Magic & Lasers anchors; pass a color for contexts
/// such as a selected blue row that need a monochrome activity mark.
struct OrbitingDots: View {
    var color: Color? = nil     // nil = the three-color activity palette
    var diameter: CGFloat = 20
    var allowsVisualOverflow = false
    var showsGlow = true
    /// Compact activity marks retain their established dot size. Hero/loading contexts opt in so
    /// both the orbit and the dots grow with the advertised frame.
    var scalesDotsWithDiameter = false

    var body: some View {
        LayerBackedOrbitingDots(
            color: color,
            allowsVisualOverflow: allowsVisualOverflow,
            showsGlow: showsGlow,
            scalesDotsWithDiameter: scalesDotsWithDiameter)
            .frame(width: diameter, height: diameter)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// A quiet-until-hovered message action (Retry / Fork), matching CopyButton's style.
struct MsgActionButton: View {
    let icon: String
    let label: String
    var help: String? = nil
    var scale: CGFloat = 1
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11 * scale, weight: .semibold))
                .frame(width: 18 * scale, height: 18 * scale)
            .foregroundStyle(hovering ? Color.nText : .secondary)
            .padding(3)
            .background(
                // The accent tint, not `nElevated`. These buttons sit on a message card in the
                // transcript and other message surfaces against the window background, where
                // `nElevated` is within four 8-bit levels of what is behind it and the hover
                // simply does not appear. David reported the pin as having no hover; it had one
                // that could not be seen, which is the same thing from where he was sitting.
                RoundedRectangle(cornerRadius: 6)
                    .fill(hovering ? Color.nAccent.opacity(0.14) : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help(help ?? label)
        .accessibilityLabel(label)
    }
}

/// Watches the enclosing NSScrollView for *user* scrolling (live-scroll notifications,
/// which programmatic `scrollTo` and content growth do not fire) and reports whether the
/// user is at the bottom — so the transcript can stop auto-scrolling once they scroll up.
/// Grabs the transcript's underlying NSScrollView so auto-follow can settle with an APPKIT scroll,
/// which is clamped to the document's real bounds by construction. SwiftUI's `scrollTo` can chase
/// estimated row heights while content is changing; `scrollToBottom()` here cannot leave the
/// document's laid-out bounds.
/// THE transcript scroll authority — auto-follow and stickiness live HERE, in AppKit, and
/// nowhere else. Why: every prior fix layered another SwiftUI mechanism on top (onChange
/// follows, a 100ms heartbeat, a geometry modifier, an app-wide wheel monitor), and they
/// fought — SwiftUI's scrollTo targets ESTIMATED row heights, so during a turn the
/// heartbeat overshot past the true bottom and the AppKit clamp yanked it back, 10×/s: the
/// visible "bounce". And the app-wide wheel monitor meant a scroll anywhere (sidebar, another
/// window) + a reflow nudge silently detached the follow: "auto-scroll stopped working".
///
/// The rules here are three, and each has ONE source of truth:
///  • FOLLOW: native row-geometry publications and view frame changes feed this one controller,
///    which pins the clip view to the final row — unanimated and clamped to real transcript content.
///  • DETACH/RE-ATTACH: only genuine user input over THIS scroll view — live-scroll
///    notifications (user-initiated by definition: gestures + scroller drags) and a wheel
///    monitor hit-tested to this scroll view. The first actual movement away detaches, even inside
///    the near-bottom reattach zone. Programmatic scrolling produces neither signal.
///  • GESTURE PRIORITY: while a live scroll or wheel event is being applied, growth-pinning pauses
///    — content streaming in never fights the user's fingers.
@MainActor
final class TranscriptPinController {
    weak var scrollView: NSScrollView? {
        didSet { if scrollView !== oldValue { attach() } }
    }
    /// Following the bottom? Set true by an explicit landing/reattach and flipped only by actual
    /// user-driven movement away from the bottom.
    var pinned = true
    /// Fired when USER input re-attaches the pin (detached → back at the bottom). ContentView
    /// re-lands the AppKit viewport at the exact tail after a fast user scroll.
    var onReattach: (() -> Void)?

    /// Within this of the bottom still counts as "at the bottom" (> 22pt spacer + 16pt padding,
    /// or scrolling back down could never re-attach).
    private static let bottomThreshold: CGFloat = 48

    private var observers: [NSObjectProtocol] = []
    private var wheelMonitor: Any?
    /// AppKit's local wheel monitor runs before the scroll view consumes the event. Keep pinning
    /// suspended until the next main-loop turn, when the clip-view origin reflects that event.
    private var wheelEvaluationsInFlight = 0
    private var liveScrollActive = false
    private var lastLiveScrollY: CGFloat?
    /// Entering the bottom threshold during a live gesture marks reattachment, but the callback
    /// must wait until AppKit has finished applying every scroll event. Otherwise its queued
    /// landing is correctly rejected as user interaction and never retried at gesture end.
    private var reattachPending = false
    private var attachmentGeneration: UInt = 0
    /// Total native clip-origin movement that preserved a content anchor rather than representing
    /// user input. Trackpad gestures deliver both live-scroll notifications and local wheel events;
    /// queued wheel evaluations rebase their captured origins through this cumulative delta.
    private var nativeViewportCompensation: CGFloat = 0
    /// Invalidates queued open/switch/new-turn settles as soon as the user touches the transcript.
    /// A stale landing must never reassert follow after a detach begins.
    private var landingGeneration: UInt = 0
    private func attach() {
        detach()
        guard let sv = scrollView, let doc = sv.documentView else { return }
        doc.postsFrameChangedNotifications = true
        sv.postsFrameChangedNotifications = true
        let nc = NotificationCenter.default
        // Document growth/shrink (streaming tokens, thinking row, row realization) → re-pin.
        observers.append(nc.addObserver(forName: NSView.frameDidChangeNotification,
                                        object: doc, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.documentChanged() }
        })
        // Viewport resize (window/panel drag) keeps the bottom pinned too.
        observers.append(nc.addObserver(forName: NSView.frameDidChangeNotification,
                                        object: sv, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.documentChanged() }
        })
        // User-initiated scrolling (gestures + scroller-knob drags): AppKit posts live-scroll
        // notifications ONLY for user interaction — programmatic scroll(to:) never does.
        observers.append(nc.addObserver(forName: NSScrollView.willStartLiveScrollNotification,
                                        object: sv, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.liveScrollBegan() }
        })
        observers.append(nc.addObserver(forName: NSScrollView.didLiveScrollNotification,
                                        object: sv, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.liveScrollMoved() }
        })
        observers.append(nc.addObserver(forName: NSScrollView.didEndLiveScrollNotification,
                                        object: sv, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.liveScrollEnded() }
        })
        // Legacy wheel events (a physical mouse wheel can skip live-scroll) — hit-tested to
        // THIS scroll view, unlike the old app-wide watcher that let a sidebar scroll detach us.
        wheelMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            // Local monitors are delivered on the main run loop, which is what `assumeIsolated`
            // asserts. Return the event *outside* that block: `NSEvent` is explicitly non-Sendable,
            // so handing it back as the isolated block's result is the part the compiler rejects.
            // Every path already returned the event unchanged, so this only moves the return.
            MainActor.assumeIsolated {
                guard let self, let sv = self.scrollView, let win = sv.window,
                      event.window === win else { return }
                let p = sv.convert(event.locationInWindow, from: nil)
                if sv.bounds.contains(p) { self.wheelWillDispatch() }
            }
            return event
        }
        documentChanged()
    }

    private func detach() {
        attachmentGeneration &+= 1
        liveScrollActive = false
        lastLiveScrollY = nil
        reattachPending = false
        wheelEvaluationsInFlight = 0
        nativeViewportCompensation = 0
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        if let m = wheelMonitor { NSEvent.removeMonitor(m); wheelMonitor = nil }
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        if let m = wheelMonitor { NSEvent.removeMonitor(m) }
    }

    private func bottomTargetY(_ sv: NSScrollView, _ doc: NSView) -> CGFloat {
        let clip = sv.contentView
        // NSTableView's document frame can temporarily retain its previous height after a hosted
        // SwiftUI row shrinks. That trailing frame is not transcript content: pinning against it
        // leaves the real tail partway up the viewport and exposes a large blank region below it.
        // Native row geometry is authoritative for this host, while the frame remains the fallback
        // for any non-table document view.
        let contentHeight: CGFloat
        if let table = doc as? NSTableView, table.numberOfRows > 0 {
            contentHeight = table.rect(ofRow: table.numberOfRows - 1).maxY
        } else {
            contentHeight = doc.frame.height
        }
        return doc.isFlipped
            ? max(-sv.contentInsets.top,
                  contentHeight - clip.bounds.height + sv.contentInsets.bottom)
            : 0
    }

    private var distanceFromBottom: CGFloat {
        guard let sv = scrollView, let doc = sv.documentView else { return 0 }
        let target = bottomTargetY(sv, doc)
        let current = sv.contentView.bounds.origin.y
        // Clamp elastic overscroll to zero. Its rebound can move in the same direction as a true
        // detach, but it must not turn off follow until the viewport is inside real content.
        return doc.isFlipped ? max(0, target - current) : max(0, current - target)
    }

    private var viewportY: CGFloat { scrollView?.contentView.bounds.origin.y ?? 0 }

    private var userInteracting: Bool {
        liveScrollActive || wheelEvaluationsInFlight > 0
    }

    /// A native row may replace an estimate with its measured height after the person has stopped
    /// following the tail. During a trackpad live scroll, preserving the same visible row is scroll
    /// anchoring: it rebases changed document coordinates without undoing any finger movement.
    /// Local wheel evaluations rebase their captured origins through the cumulative compensation,
    /// so both AppKit input paths can preserve content without confusing it for finger movement.
    var mayPreserveDetachedViewportAnchor: Bool {
        !pinned
    }

    /// Row-height correction can move the clip origin solely to keep the same content stationary.
    /// Rebase the live-scroll sample by that exact delta so the next genuine gesture update is
    /// compared in the new document coordinate system rather than misread as movement toward the
    /// bottom (which could spuriously reattach inside the 48-point zone).
    func nativeViewportWasCompensated(by delta: CGFloat) {
        guard delta.isFinite, abs(delta) > 0.5 else { return }
        nativeViewportCompensation += delta
        if let lastLiveScrollY {
            self.lastLiveScrollY = lastLiveScrollY + delta
        }
    }

    /// Start an explicit open/switch/new-turn landing. The returned generation is a cancellation
    /// token for its next-runloop settle; user input invalidates it immediately.
    func beginLanding() -> UInt {
        landingGeneration &+= 1
        reattachPending = false
        pinned = true
        return landingGeneration
    }

    func canSettleLanding(_ generation: UInt) -> Bool {
        generation == landingGeneration && pinned && !userInteracting
    }

    private func cancelPendingLanding() {
        landingGeneration &+= 1
    }

    private var pinScheduled = false

    private func documentChanged() {
        guard pinned, !userInteracting, !pinScheduled else { return }
        // Frame-change notifications post MID-layout; snapping there can expose a region SwiftUI
        // hasn't painted yet (a blank flash during fast bursts). Coalesce to the next runloop
        // turn so the pass completes, then snap once — still every-frame-fresh, never mid-pass.
        pinScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pinScheduled = false
            if self.pinned, !self.userInteracting { self.pinToBottom() }
        }
    }

    /// The native table's variable row geometry can change without changing its retained document
    /// frame. Let the host publish that event to this existing controller instead of introducing a
    /// second follow mechanism.
    func nativeDocumentGeometryChanged() {
        if !userInteracting { clampViewportToDocument() }
        documentChanged()
    }

    /// Elastic scrolling and a shrinking native table can leave the clip origin beyond the final
    /// transcript row even after the document frame is corrected. Clamp only impossible geometry;
    /// a valid detached reading position remains untouched and does not re-enable following.
    private func clampViewportToDocument() {
        guard let sv = scrollView, let doc = sv.documentView, doc.isFlipped else { return }
        let clip = sv.contentView
        let minimumY = -sv.contentInsets.top
        let maximumY = bottomTargetY(sv, doc)
        let y = min(max(clip.bounds.origin.y, minimumY), maximumY)
        guard abs(clip.bounds.origin.y - y) > 0.5 else { return }
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: y))
        sv.reflectScrolledClipView(clip)
    }

    private func liveScrollBegan() {
        cancelPendingLanding()
        liveScrollActive = true
        lastLiveScrollY = viewportY
    }

    private func liveScrollMoved() {
        cancelPendingLanding()
        let previous = lastLiveScrollY ?? viewportY
        evaluateUserMovement(from: previous)
        lastLiveScrollY = viewportY
    }

    private func liveScrollEnded() {
        cancelPendingLanding()
        let previous = lastLiveScrollY ?? viewportY
        evaluateUserMovement(from: previous)
        lastLiveScrollY = nil
        liveScrollActive = false
        clampViewportToDocument()
        finishReattachIfIdle()
    }

    /// Capture the pre-event origin, then evaluate after AppKit has delivered the wheel event to
    /// the scroll view. This closes the old race where we sampled y=bottom, left `pinned` true, and
    /// a streaming frame change snapped back down before the delayed position check ran.
    func wheelWillDispatch() {
        cancelPendingLanding()
        let previous = viewportY
        let attachment = attachmentGeneration
        let compensationAtDispatch = nativeViewportCompensation
        wheelEvaluationsInFlight += 1
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard self.attachmentGeneration == attachment else { return }
            let rebasedPrevious = previous
                + (self.nativeViewportCompensation - compensationAtDispatch)
            self.evaluateUserMovement(from: rebasedPrevious)
            self.wheelEvaluationsInFlight = max(0, self.wheelEvaluationsInFlight - 1)
            if !self.userInteracting { self.clampViewportToDocument() }
            self.finishReattachIfIdle()
        }
    }

    /// Detach asymmetrically: the first actual movement away from the bottom wins, even inside the
    /// 48pt reattach zone. Reattach only when movement is not away and the user reaches that zone.
    /// Document growth alone cannot change this state because it does not change the user-motion
    /// direction sampled here.
    private func evaluateUserMovement(from previousY: CGFloat) {
        guard let doc = scrollView?.documentView else { return }
        let currentY = viewportY
        let movedAwayDirection = doc.isFlipped
            ? currentY < previousY - 0.5
            : currentY > previousY + 0.5
        let movedAway = movedAwayDirection && distanceFromBottom > 0.5
        if movedAway {
            pinned = false
            reattachPending = false
            return
        }
        if !pinned, distanceFromBottom <= Self.bottomThreshold {
            pinned = true
            reattachPending = true
        }
        finishReattachIfIdle()
    }

    private func finishReattachIfIdle() {
        guard reattachPending, pinned, !userInteracting else { return }
        reattachPending = false
        onReattach?()
    }

    /// Clamped, unanimated bottom snap. Its target comes from the final native row rather than a
    /// retained table frame, so it never intentionally lands in trailing document slack. Later row
    /// measurements publish another geometry change and converge on the new tail without bouncing.
    func pinToBottom() {
        guard let sv = scrollView, let doc = sv.documentView else { return }
        let clip = sv.contentView
        // A SwiftUI scroll view under a unified title bar gets an automatic top content inset.
        // Its natural top is therefore negative (for example -52), not zero. Clamping short
        // transcripts to zero hides the first row under the title bar; keep that inset as the
        // lower bound, while tall documents still land flush at their true bottom.
        let y = bottomTargetY(sv, doc)
        guard abs(clip.bounds.origin.y - y) > 0.5 else { return }
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: y))
        sv.reflectScrolledClipView(clip)
    }
}

/// SwiftUI may create and update the representable before it has installed the view inside the
/// transcript's NSScrollView. A one-shot `enclosingScrollView` lookup can therefore miss forever,
/// leaving the sole pin controller detached. Reconnect from AppKit's actual attachment lifecycle.
@MainActor
final class TranscriptScrollProbeView: NSView {
    weak var holder: TranscriptPinController?

    init(holder: TranscriptPinController) {
        self.holder = holder
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        connect()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        connect()
    }

    override func layout() {
        super.layout()
        if holder?.scrollView == nil { connect() }
    }

    func connect(attemptsRemaining: Int = 8) {
        if let scroll = enclosingScrollView {
            holder?.scrollView = scroll
            return
        }
        // SwiftUI can finish installing the representable's ancestor chain several run-loop turns
        // after both lifecycle callbacks. Retry only during this bounded attachment window.
        guard window != nil, holder?.scrollView == nil, attemptsRemaining > 0 else { return }
        DispatchQueue.main.async { [weak self] in
            self?.connect(attemptsRemaining: attemptsRemaining - 1)
        }
    }
}

struct TranscriptScrollAccessor: NSViewRepresentable {
    let holder: TranscriptPinController
    func makeNSView(context: Context) -> TranscriptScrollProbeView {
        TranscriptScrollProbeView(holder: holder)
    }
    func updateNSView(_ nsView: TranscriptScrollProbeView, context: Context) {
        nsView.holder = holder
        nsView.connect()
    }
}


// MARK: - Composer isolation

/// The composer's draft state, held as a plain object so ContentView can OWN it without
/// OBSERVING it — only ComposerCard subscribes. A keystroke therefore re-renders the card
/// alone; the transcript (whose visible rows re-parse JSON/markdown per evaluation) is
/// untouched. This isolation is what fixed composer typing lag on long conversations.
final class ComposerDraft: ObservableObject {
    @Published var text = ""
    @Published var height: CGFloat = ChatInput.minimumSingleLineHeight(fontSize: 13)
    /// Non-published ownership for synchronous external draft routing. A bridge can change ids one
    /// SwiftUI pass before this isolated composer reloads, so text alone cannot identify its owner.
    var conversationID: UUID?
    /// Voice input: the composer text as it was before dictation started, so the streamed
    /// transcript can be spliced in after it.
    @Published var dictationBase = ""

    func resetHeight(fontSize: CGFloat) {
        height = ChatInput.minimumSingleLineHeight(fontSize: fontSize)
    }
}

enum ComposerDeliveryAction: Equatable {
    case startTurn
    case guideCurrentTurn
    case sendNext
    case stopAndRedirect
}

/// The small bridge projection the native composer actually renders.
///
/// `AgentBridge` publishes every provider and delegated-agent observation. Observing that whole
/// object from `ComposerCard` therefore updated its `NSViewRepresentable` for activity that did not
/// change the editor at all. Worse, `hasStoppableConversationWork` deliberately resolves ownership
/// across every live bridge and its retained activity ledger; the old computed `deliveryPolicy`
/// asked for it repeatedly during every body evaluation, including every keystroke.
///
/// ContentView already observes the bridge. Capture each render input once at that boundary, then
/// let the equatable card ignore activity-only parent updates. Draft and dictation remain observed
/// by the card itself, so native edits still update Send state immediately without touching the
/// expensive ownership path.
struct ComposerPresentationState: Equatable {
    let runtimeReady: Bool
    let turnReserved: Bool
    let canGuide: Bool
    let providerAccessPending: Bool
    let providerSetupRequired: Bool
    let stoppableWork: Bool
    let armedSkill: SlashCommandInfo?
    let guidanceUnavailableReason: String?
    let slashCommands: [SlashCommandInfo]
    let cwd: String
    let conversationID: UUID?

    @MainActor
    init(bridge: AgentBridge) {
        let reserved = bridge.currentConversationHasReservedTurn
        runtimeReady = bridge.composerAcceptsSubmission
        turnReserved = reserved
        canGuide = bridge.guidanceIsDefaultForCurrentTurn
        providerAccessPending = bridge.currentProviderAccessRequest != nil
        providerSetupRequired = bridge.needsProviderSetup
        // An owned root reservation or this bridge's live delegate graph is already sufficient.
        // Resolve the process-wide duplicate-viewer fallback only when neither is present, and at
        // most once per bridge-driven update. Draft keystrokes reuse this Boolean entirely.
        stoppableWork = reserved
            || bridge.hasRunningDelegate
            || bridge.hasStoppableConversationWork
        armedSkill = bridge.armedSkill
        guidanceUnavailableReason = bridge.guidanceUnavailableReason
        slashCommands = bridge.slashCommands
        cwd = bridge.cwd
        conversationID = bridge.currentID
    }

    func deliveryPolicy(hasText: Bool) -> ComposerDeliveryPolicy {
        ComposerDeliveryPolicy(
            hasText: hasText,
            runtimeReady: runtimeReady,
            turnReserved: turnReserved,
            canGuide: canGuide,
            providerAccessPending: providerAccessPending,
            providerSetupRequired: providerSetupRequired,
            stoppableWork: stoppableWork)
    }
}

/// A provider-access request can replace setup UI only for its own provider family. A pending
/// OpenAI request must not hide a simultaneous Vertex reconnect requirement (or vice versa).
struct ProviderSetupBannerPolicy {
    static func shouldShow(
        needsProviderSetup: Bool,
        currentAccess: ModelAccess,
        request: ProviderAccessRequest?
    ) -> Bool {
        needsProviderSetup && request?.maker != currentAccess.maker
    }
}

/// Submission policy shared by the Return-key action and the visible composer controls. A provider
/// that is busy cannot start a new turn, but its already-reserved turn remains a valid target for
/// guidance—or for a durable next-turn message when native guidance is unavailable.
struct ComposerDeliveryPolicy: Equatable {
    let hasText: Bool
    let runtimeReady: Bool
    let turnReserved: Bool
    let canGuide: Bool
    var providerAccessPending: Bool = false
    /// A definitive credential rejection closes both new-turn and in-flight delivery. A reserved
    /// route may still expose Stop, but it cannot make a disconnected provider accept more work.
    var providerSetupRequired: Bool = false
    /// Conversation-level work can outlive the root turn. Keep this separate from `turnReserved`:
    /// delegates need a Stop affordance, but they are not a valid Guide/Send Next target.
    var stoppableWork: Bool = false

    var canSubmit: Bool {
        !providerAccessPending
            && !providerSetupRequired
            && hasText
            && (runtimeReady || turnReserved)
    }

    var showsInFlightControls: Bool {
        turnReserved
    }

    var showsStopControl: Bool {
        turnReserved || stoppableWork
    }

    var defaultAction: ComposerDeliveryAction {
        guard turnReserved else { return .startTurn }
        return canGuide ? .guideCurrentTurn : .sendNext
    }

    /// Preserve an explicit in-flight choice while it remains valid. Merely choosing a mode never
    /// submits the draft; Return/the primary button later asks the composer to execute this result.
    func resolvedAction(selecting selection: ComposerDeliveryAction?) -> ComposerDeliveryAction {
        guard turnReserved else { return .startTurn }
        switch selection {
        case .guideCurrentTurn where canGuide:
            return .guideCurrentTurn
        case .sendNext:
            return .sendNext
        case .stopAndRedirect:
            return .stopAndRedirect
        default:
            return defaultAction
        }
    }
}

/// The unified composer card: text field on top, controls inside the card at the bottom
/// (dictation transforms the row in place). Observes the draft + dictation so their churn
/// (keystrokes, waveform levels) invalidates only this subtree.
struct ComposerCard: View, Equatable {
    /// Kept as an unobserved action target. Every value read while rendering lives in
    /// `presentation`; subscribing here would bypass the equatable isolation above.
    let bridge: AgentBridge
    let presentation: ComposerPresentationState
    @ObservedObject var draft: ComposerDraft
    @ObservedObject var dictation: SpeechDictation
    let chatScale: CGFloat
    let onSubmit: (ComposerDeliveryAction) -> Void
    @State private var pickingFiles = false
    @State private var selectedInFlightAction: ComposerDeliveryAction?

    private var deliveryPolicy: ComposerDeliveryPolicy {
        presentation.deliveryPolicy(
            hasText: ChatInput.hasSubmittableText(draft.text))
    }

    static func == (lhs: ComposerCard, rhs: ComposerCard) -> Bool {
        lhs.bridge === rhs.bridge
            && lhs.presentation == rhs.presentation
            && lhs.draft === rhs.draft
            && lhs.dictation === rhs.dictation
            && lhs.chatScale == rhs.chatScale
    }

    private func primaryHelpText(for action: ComposerDeliveryAction) -> String {
        switch action {
        case .guideCurrentTurn: return "Guide the current turn"
        case .sendNext: return "Send after the current turn"
        case .stopAndRedirect: return "Stop the current turn and send this message"
        case .startTurn: return "Send"
        }
    }

    private func primaryAccessibilityText(for action: ComposerDeliveryAction) -> String {
        switch action {
        case .guideCurrentTurn: return "Guide current turn"
        case .sendNext: return "Send next"
        case .stopAndRedirect: return "Stop and redirect"
        case .startTurn: return "Send message"
        }
    }

    private func primaryIcon(for action: ComposerDeliveryAction) -> ComposerRoadSignKind {
        switch action {
        case .guideCurrentTurn: return .curveAhead
        case .sendNext: return .yield
        case .stopAndRedirect: return .detour
        case .startTurn: return .send
        }
    }

    private func submitSelectedMode() {
        let policy = deliveryPolicy
        guard policy.canSubmit else { return }
        onSubmit(policy.resolvedAction(selecting: selectedInFlightAction))
    }

    private func choose(_ action: ComposerDeliveryAction) {
        selectedInFlightAction = deliveryPolicy.resolvedAction(selecting: action)
    }

    /// A skill armed from the inspector, shown exactly like a file or image attachment: visible,
    /// removable, and consumed by the next send. Without the pill, arming would be invisible state
    /// that silently rewrites the next message — which is the kind of thing that makes an app feel
    /// haunted.
    private func armedSkillPill(_ skill: SlashCommandInfo) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "sparkle").font(.caption2)
            Text(skill.invocation).font(.system(size: 11, design: .monospaced))
            Button { bridge.armedSkill = nil } label: {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove the armed skill")
        }
        .foregroundStyle(Color.nInfoText)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Capsule().fill(Color.nAccent.opacity(0.16)))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 2)
        .help("Your next message will run \(skill.invocation)")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Skill \(skill.invocation) armed for your next message")
    }

    var body: some View {
        // `hasSubmittableText` walks the authored draft (which can include large pasted payloads).
        // Resolve both it and the selected action once per keystroke, then share those values across
        // the native editor, controls, outline, and change handlers in this render pass.
        let policy = deliveryPolicy
        let action = policy.resolvedAction(selecting: selectedInFlightAction)
        VStack(spacing: 2) {
            if let skill = presentation.armedSkill { armedSkillPill(skill) }
            ChatInput(text: $draft.text, height: $draft.height, isEnabled: true,
                      fontSize: 13 * chatScale, focusController: bridge.composerFocusOwner,
                      onSend: submitSelectedMode,
                      onInterject: { onSubmit(.stopAndRedirect) },
                      slashCommands: presentation.slashCommands, cwd: presentation.cwd,
                      conversationID: presentation.conversationID,
                      isTurnInFlight: policy.showsInFlightControls,
                      onArtifactReference: bridge.referenceArtifact,
                      canResolvePromisedAttachment: {
                          conversationID, pendingPayload in
                          ChatInput.resolvingPendingFilePromise(
                              in: bridge.draft(for: conversationID),
                              pendingPayload: pendingPayload,
                              replacementPayload: "") != nil
                      },
                      onPromisedAttachmentResolution: {
                          conversationID, pendingPayload, replacementPayload in
                          let stored = bridge.draft(for: conversationID)
                          guard let resolved = ChatInput.resolvingPendingFilePromise(
                              in: stored,
                              pendingPayload: pendingPayload,
                              replacementPayload: replacementPayload)
                          else { return false }
                          bridge.setDraft(
                              resolved,
                              for: conversationID)
                          return true
                      },
                      onPromisedAttachmentTransferBegan: {
                          bridge.retainForPromisedAttachment($0)
                      },
                      onPromisedAttachmentTransferEnded: {
                          bridge.releaseForPromisedAttachment($0)
                      })
                // Never render below TextKit's actual one-line geometry. The coordinator still
                // owns multiline growth; this floor prevents the first key after a reset from
                // changing the adjacent transcript viewport.
                .frame(height: max(
                    draft.height,
                    ChatInput.minimumSingleLineHeight(fontSize: 13 * chatScale)))
                .padding(.horizontal, 4)
            if policy.showsInFlightControls,
               let notice = presentation.guidanceUnavailableReason {
                HStack(spacing: 5) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 9, weight: .semibold))
                    Text(notice)
                        .font(.system(size: 10.5, weight: .medium))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.top, 1)
                .accessibilityElement(children: .combine)
            }
            if dictation.isRecording {
                HStack(spacing: 10) {
                    VoiceWaveform(levels: dictation.levels)
                        .frame(height: 24)
                    Button {
                        dictation.stop()
                        draft.text = draft.dictationBase   // discard the dictated splice, keep what was typed before
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 28, height: 28)
                            .background(Circle().fill(Color.nMuted.opacity(0.35)))
                    }
                    .buttonStyle(.plain)
                    .help("Cancel dictation")
                    .accessibilityLabel("Cancel dictation")
                    Button { dictation.stop() } label: {
                        Image(systemName: "checkmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 28, height: 28)
                            .background(Circle().fill(Color.nSolidActionFill))
                    }
                    .buttonStyle(.plain)
                    .help("Accept dictation")
                    .accessibilityLabel("Accept dictation")
                }
                .padding(.horizontal, 2)
                .transition(.opacity)
            } else {
                HStack(spacing: 4) {
                    attachButton
                    micButton
                    Spacer()
                    if policy.showsInFlightControls {
                        StopButton { bridge.stopConversationWork() }
                        HStack(spacing: 0) {
                            SendButton(
                                enabled: policy.canSubmit,
                                action: submitSelectedMode,
                                helpText: primaryHelpText(for: action),
                                accessibilityText: primaryAccessibilityText(for: action),
                                icon: primaryIcon(for: action))
                            ComposerDeliveryMenuButton(
                                canGuide: presentation.canGuide,
                                selected: action,
                                choose: choose)
                                .frame(width: 22, height: 34)
                        }
                    } else if policy.showsStopControl {
                        StopButton(
                            action: { bridge.stopConversationWork() },
                            helpText: "Stop active work (⌘.)",
                            accessibilityText: "Stop active work",
                            accessibilityHintText: "Stops this conversation’s active agents")
                    } else {
                        SendButton(enabled: policy.canSubmit, action: submitSelectedMode)
                    }
                }
                .padding(.horizontal, 2)
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 6)
        .padding(.bottom, 6)
        // The composer is our signature surface: a floating Liquid Glass bar on
        // Tahoe, the neutral filled field on older systems.
        .glassSurface(cornerRadius: 18, legacyStroke: Color.nMuted.opacity(0.5))
        .overlay {
            if policy.showsStopControl {
                LayerBackedComposerActivityOutline(cornerRadius: 18)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                    .transition(.opacity)
            }
        }
        // Splice the live transcript in after whatever was already typed.
        .onChange(of: dictation.transcript) { _, text in
            guard dictation.isRecording else { return }
            draft.text = dictatedInput(text)
        }
        // If the user TYPES while the mic is still live (e.g. after submitting a dictated
        // message), rebase dictation onto their edited text so the next recognition partial
        // appends after it instead of overwriting it — otherwise the typed text is silently lost.
        // Typing re-arms this lane's warm provider process when the idle one has lapsed. Throttled
        // in the bridge, so a keystroke costs a date comparison.
        .onChange(of: draft.text) { _, _ in bridge.noteComposerActivity() }
        .onChange(of: draft.text) { _, newValue in
            guard dictation.isRecording, newValue != dictatedInput(dictation.transcript) else { return }
            draft.dictationBase = newValue
            dictation.reset()
        }
        .onChange(of: presentation.conversationID) { _, _ in
            selectedInFlightAction = nil
        }
        .onChange(of: policy.showsInFlightControls) { _, isActive in
            if !isActive { selectedInFlightAction = nil }
        }
        .onChange(of: presentation.canGuide) { _, canGuide in
            if !canGuide, selectedInFlightAction == .guideCurrentTurn {
                selectedInFlightAction = .sendNext
            }
        }
        // Standard file attach uses the exact same ordered intake policy as a native drop. Scoped
        // picker access stays open only while generic bytes are copied into conversation storage.
        .fileImporter(isPresented: $pickingFiles, allowedContentTypes: [.item],
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                appendPickedAttachmentURLs(urls)
            }
        }
    }

    private func appendPickedAttachmentURLs(_ urls: [URL]) {
        var budget = ConversationAttachmentImportBudget()
        for url in urls {
            guard let maximumBytes = budget.beginAttachment() else {
                if let message = budget.takeLimitMessage() {
                    draft.text += (draft.text.isEmpty ? "" : " ") + message + " "
                }
                break
            }
            let intake = ConversationAttachmentIntake.ingest(
                url,
                conversationID: bridge.currentID,
                needsSecurityScopedAccess: true,
                maximumBytes: maximumBytes)
            budget.recordCommittedBytes(intake.committedByteCount)
            if case .artifact(let reference) = intake {
                bridge.referenceArtifact(reference)
            }
            draft.text += (draft.text.isEmpty ? "" : " ")
                + intake.promptPayload + " "
        }
        bridge.focusComposer()
    }

    /// The composer text = whatever was already there (dictationBase) + the live transcript.
    private func dictatedInput(_ transcript: String) -> String {
        guard !transcript.isEmpty else { return draft.dictationBase }
        let sep = (draft.dictationBase.isEmpty || draft.dictationBase.hasSuffix(" ")) ? "" : " "
        return draft.dictationBase + sep + transcript
    }

    /// Attach a file from disk — paths land in the draft like a drag-drop. (The live-document
    /// app picker that used to live here was removed with the feature's entry points.)
    /// Photos, camera, screen capture, and files. The paperclip used to open the file importer on one
    /// click; option-clicking the `+` still does exactly that.
    private var attachButton: some View {
        ComposerAddMenuButton(
            addFiles: { pickingFiles = true },
            attach: { urls in
                appendAttachmentURLs(urls, needsSecurityScopedAccess: false)
            })
        .frame(width: 28, height: 28)
        .hoverHighlight()
        .help("Add photos, files, or a screen capture. Option-click for files.")
        .accessibilityLabel("Add to message")
    }

    /// Captured and exported files are already ours, so they need no security scope. Otherwise this
    /// is the same ordered intake the file importer and native drops use, budget included.
    private func appendAttachmentURLs(_ urls: [URL], needsSecurityScopedAccess: Bool) {
        guard !urls.isEmpty else { return }
        var budget = ConversationAttachmentImportBudget()
        for url in urls {
            guard let maximumBytes = budget.beginAttachment() else {
                if let message = budget.takeLimitMessage() {
                    draft.text += (draft.text.isEmpty ? "" : " ") + message + " "
                }
                break
            }
            let intake = ConversationAttachmentIntake.ingest(
                url,
                conversationID: bridge.currentID,
                needsSecurityScopedAccess: needsSecurityScopedAccess,
                maximumBytes: maximumBytes)
            budget.recordCommittedBytes(intake.committedByteCount)
            if case .artifact(let reference) = intake {
                bridge.referenceArtifact(reference)
            }
            draft.text += (draft.text.isEmpty ? "" : " ") + intake.promptPayload + " "
        }
        bridge.focusComposer()
    }

    /// Push-to-dictate: on-device voice input spliced into the composer.
    private var micButton: some View {
        Button {
            if dictation.isRecording {
                dictation.stop()
            } else {
                draft.dictationBase = draft.text
                dictation.start()
            }
        } label: {
            Image(systemName: dictation.isRecording ? "mic.fill" : "mic")
                .font(.system(size: 15))
                .foregroundStyle(dictation.isRecording ? Color.red : Color.secondary)
                .frame(width: 28, height: 28) // in-card control row sizing
        }
        .buttonStyle(.plain)
        .hoverHighlight()
        .help(dictation.isRecording ? "Stop dictation" : "Dictate (voice input)")
        .accessibilityLabel(dictation.isRecording ? "Stop dictation" : "Start voice input")
    }
}

/// A subtle rounded highlight that appears under the pointer — the standard macOS "button lights
/// up on hover" affordance for bare icon buttons (composer controls, etc.).
private struct HoverHighlight: ViewModifier {
    @State private var hovering = false
    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(hovering ? Color.nElevated : Color.clear))
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
    }
}
extension View {
    func hoverHighlight() -> some View { modifier(HoverHighlight()) }
}


/// What kind of work is happening outside the current view.
///
/// Pure and separate from the view because the categories are the substance of the thing. A raw
/// process count is not a user-task count: one Vite server can have a node parent and an esbuild
/// child. Likewise, an armed wait consumes nothing and must not read as work in flight.
struct BackgroundWorkSummary: Equatable {
    var backgroundTurns: Int
    var ambientTasksRunning: Int
    var trackedProcesses: Int
    var armedWaits: Int

    var waiting: Int { armedWaits }
    var hasManagedBackgroundWork: Bool {
        ambientTasksRunning > 0 || trackedProcesses > 0
    }
    /// Always say how many, and of what.
    ///
    /// A bare "Background work" chip cannot be told apart from a stale one: it looks identical
    /// whether something is genuinely still running or the indicator failed to clear. The count is
    /// already known here, and showing it turns "why is this still up?" into an answerable question —
    /// click through and the list names the processes.
    var managedBackgroundLabel: String {
        if trackedProcesses == 0 {
            return "\(ambientTasksRunning) "
                + (ambientTasksRunning == 1 ? "task running" : "tasks running")
        }
        let processes = "\(trackedProcesses) "
            + (trackedProcesses == 1 ? "process" : "processes")
        guard ambientTasksRunning > 0 else { return processes + " running" }
        // Never a single summed number: a task and an OS process are not the same unit, and one dev
        // server can be several processes. Name both counts instead of inventing a total.
        return "\(ambientTasksRunning) "
            + (ambientTasksRunning == 1 ? "task" : "tasks") + ", " + processes
    }
    var managedBackgroundAccessibilityLabel: String {
        var parts: [String] = []
        if ambientTasksRunning > 0 {
            parts.append("\(ambientTasksRunning) ambient task"
                         + (ambientTasksRunning == 1 ? "" : "s") + " running")
        }
        if trackedProcesses > 0 {
            parts.append("agent-started background processes")
        }
        return parts.joined(separator: ", ")
    }
    var isEmpty: Bool {
        backgroundTurns == 0 && !hasManagedBackgroundWork && waiting == 0
    }
}
