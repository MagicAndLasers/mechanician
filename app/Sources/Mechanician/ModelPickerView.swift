import AppKit
import SwiftUI

/// Interactive account routes are product capabilities, not model-catalog side effects. Keep them in
/// the picker even before they have authenticated or published a catalog so the user can recover
/// the missing account from the surface where its models belong.
@MainActor
enum ModelPickerProviderPolicy {
    static func presents(_ access: ModelAccess, state: ProviderAccountStore.State) -> Bool {
        switch access {
        case .claudeSubscription, .codexSubscription, .claudeVertex:
            return true
        case .anthropicAPI, .openAIAPI, .claudeBedrock:
            return state.isAvailable
        }
    }

    static func connectionAction(
        for access: ModelAccess,
        state: ProviderAccountStore.State,
        requiresReconnect: Bool,
        isEnvironmentManaged: Bool
    ) -> ProviderAccountStore.SubscriptionConnectionAction? {
        guard access.usesInteractiveAccountFlow,
              !isEnvironmentManaged else { return nil }
        if requiresReconnect {
            return ProviderAccountStore.subscriptionConnectionAction(
                state: state, requiresReconnect: true)
        }
        switch state {
        case .checking, .disconnected, .unavailable:
            return ProviderAccountStore.subscriptionConnectionAction(
                state: state, requiresReconnect: false)
        case .connected, .configured, .managed:
            return nil
        }
    }

    /// Interactive credential storage is intentionally verified by the provider runtime, not by a
    /// second passive credential reader. Opening the picker must therefore start that lightweight
    /// runtime probe while the account is `checking`, even when a last-known catalog is cached.
    static func shouldPrepareCatalog(
        for access: ModelAccess,
        state: ProviderAccountStore.State,
        hasUsableRuntime: Bool = false
    ) -> Bool {
        // Sending and the account list intentionally have separate authorities. A live,
        // authenticated runtime is stronger evidence than a stale process-wide row and must be
        // allowed to repair that row's missing catalog.
        if hasUsableRuntime { return true }
        if state.isAvailable { return true }
        return state == .checking
            && access.usesInteractiveAccountFlow
    }
}

/// Decide which rows remain visible while one account's live catalog changes state.
///
/// Catalog refresh is enrichment, not authority, for a managed deployment: its signed declaration
/// already names the models the backend carries. Hiding that declaration while a provider probe is
/// queued made the picker look empty indefinitely whenever Vertex rejected or lost the probe.
/// Keep this projection pure so every catalog phase can be regression-tested without mounting a
/// popover or starting a provider process.
enum ModelPickerCatalogProjection {
    static func entries(
        snapshot: ModelCatalogSnapshot,
        isEligible: Bool,
        isReconnectable: Bool,
        hasAccountOperation: Bool,
        fallbackEntries: [ModelCatalogEntry],
        lastKnownEntries: [ModelCatalogEntry]
    ) -> [ModelCatalogEntry] {
        if isEligible {
            // Ready-and-empty is an authoritative provider answer. Every other non-ready phase
            // retains the best safe local projection so refresh can never remove the escape hatch.
            return snapshot.phase == .ready ? snapshot.entries : fallbackEntries
        }
        if isReconnectable || hasAccountOperation {
            // `fallbackEntries` IS the last-known rows whenever there are any; it differs only when
            // there are none, and that is the case this branch used to get wrong. A lane with no
            // cached rows rendered an empty section with a Reconnect button and no indication of
            // what reconnecting would offer, even though a built-in list existed for exactly this.
            return lastKnownEntries.isEmpty ? fallbackEntries : lastKnownEntries
        }
        return []
    }
}

/// Identity captured at the user's click, before the native popover begins dismissing. Provider
/// mutation must never follow a delayed callback into another conversation or workspace window.
struct DeferredModelSelectionContext: Equatable {
    let bridgeID: UUID
    let conversationID: UUID?
    let workspaceWindowID: ObjectIdentifier?

    func matches(
        bridgeID: UUID,
        conversationID: UUID?,
        workspaceWindowID: ObjectIdentifier?
    ) -> Bool {
        self.bridgeID == bridgeID
            && self.conversationID == conversationID
            && self.workspaceWindowID == workspaceWindowID
    }
}

enum DeferredModelSelectionOwnership {
    static func canAccept(
        hasPendingSelection: Bool,
        hasDeferredTask: Bool,
        isPresented: Bool
    ) -> Bool {
        !hasPendingSelection && !hasDeferredTask && isPresented
    }
}

/// Isolate catalog publication to the small status control. Observing the process-wide catalog from
/// `ContentView` itself would unnecessarily invalidate the transcript while four account lanes load.
struct ModelPickerButton: View {
    @ObservedObject var bridge: AgentBridge
    @Binding var isWindowOrderTransitioning: Bool
    @Environment(\.openWindow) private var openWindow
    var compact = false
    var wrapsTitle = false
    @ObservedObject private var catalogs = ModelCatalogStore.shared
    @State private var presentation = ConversationControlPopoverState()
    @State private var deferredTransition: Task<Void, Never>?
    @State private var pendingTransition: PendingTransition?

    private enum PendingAction {
        case selectModel(ModelSelection)
        case manageProviders
    }

    private struct PendingTransition {
        let token: UUID
        let action: PendingAction
        let context: DeferredModelSelectionContext
        let dismissedGeneration: UInt
    }

    var body: some View {
        let label = bridge.modelDisplayName(for: bridge.selectedModelSelection)
        Button {
            if presentation.isPresented {
                cancelDeferredTransition()
                scheduleCleanup(for: presentation.dismiss())
            } else if deferredTransition != nil {
                // Selection owns this short interval. Do not reopen the old picker before the
                // provider mutation has landed against the dismissed presentation.
                return
            } else {
                presentation.present(title: label)
            }
        } label: {
            MechanicianControlTrigger(
                // Compact is a genuinely icon-only escape hatch at the minimum chat width. The
                // accessibility value and help text still expose the selected model.
                title: presentation.triggerTitle(current: label, compact: compact),
                systemImage: "cpu",
                showsChevron: true,
                maxTitleWidth: compact ? 96 : (wrapsTitle ? 110 : 160),
                wrapsTitle: wrapsTitle)
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help("Choose model")
        .accessibilityLabel("Model")
        .accessibilityValue(label)
        .popover(isPresented: presentedBinding(currentTitle: label), arrowEdge: .bottom) {
            ModelPickerView(
                bridge: bridge,
                isPresented: presentedBinding(currentTitle: label),
                onSelect: selectModel,
                onManageProviders: manageProviders)
        }
        .onDisappear { cancelDeferredTransition() }
    }

    private func presentedBinding(currentTitle: String) -> Binding<Bool> {
        Binding(
            get: { presentation.isPresented },
            set: { presented in
                if presented {
                    if deferredTransition == nil, !presentation.isPresented {
                        presentation.present(title: currentTitle)
                    }
                } else {
                    // SwiftUI may write `false` again as the native popover finishes closing.
                    // Do not cancel or unpin an accepted selection: it owns the native order-off
                    // wait and clears its generation on every completion/cancellation path.
                    let dismissedGeneration = presentation.dismiss()
                    if pendingTransition == nil {
                        scheduleCleanup(for: dismissedGeneration)
                    }
                }
            })
    }

    private func selectModel(_ selection: ModelSelection, pickerWindow: NSWindow?) {
        beginTransition(.selectModel(selection), pickerWindow: pickerWindow)
    }

    private func manageProviders(pickerWindow: NSWindow?) {
        beginTransition(.manageProviders, pickerWindow: pickerWindow)
    }

    private func beginTransition(_ action: PendingAction, pickerWindow: NSWindow?) {
        // An already-accepted click owns the native dismissal interval. A double-click, repeated
        // Return key, or second queued SwiftUI action must not cancel it before `.disabled` has had
        // a render pass to make the rows inert.
        guard DeferredModelSelectionOwnership.canAccept(
                hasPendingSelection: pendingTransition != nil,
                hasDeferredTask: deferredTransition != nil,
                isPresented: presentation.isPresented),
              let workspaceWindow = bridge.window,
              let pickerWindow,
              pickerWindow !== workspaceWindow,
              pickerWindow.parent === workspaceWindow,
              pickerWindow.isVisible else { return }
        // Changing providers republishes every conversation control and can reflow this anchor.
        // Retire the presentation state *before* evaluating bridge.selectModel: putting that call
        // inside dismissIfAccepted's argument evaluated the provider mutation first and left the
        // popover eligible for SwiftUI to re-show during the same layout cycle. That reproduced
        // FB23642313 in NSRemoteView even after the editor-retirement delay. A final validation
        // failure now leaves the picker safely dismissed; the bridge still publishes its exact
        // explanation, and the user can reopen the picker against the new authoritative state.
        let context = DeferredModelSelectionContext(
            bridgeID: bridge.bridgeID,
            conversationID: bridge.currentID,
            workspaceWindowID: ObjectIdentifier(workspaceWindow))
        let dismissedGeneration = presentation.retireBeforeWindowOrderSensitiveMutation()
        let token = UUID()
        pendingTransition = PendingTransition(
            token: token,
            action: action,
            context: context,
            dismissedGeneration: dismissedGeneration)
        isWindowOrderTransitioning = true
        deferredTransition = RemoteTextServiceSafety.deferUntilWindowIsNoLongerVisible(
            from: pickerWindow
        ) { didOrderOff in
            finishNativeDismissal(token: token, didOrderOff: didOrderOff)
        }
    }

    private func cancelDeferredTransition() {
        deferredTransition?.cancel()
        deferredTransition = nil
        if let pendingTransition {
            self.pendingTransition = nil
            scheduleCleanup(for: pendingTransition.dismissedGeneration)
        }
        isWindowOrderTransitioning = false
    }

    private func finishNativeDismissal(token: UUID, didOrderOff: Bool) {
        guard let pendingTransition,
              pendingTransition.token == token else { return }
        deferredTransition = nil
        guard didOrderOff,
              pendingTransition.context.matches(
                bridgeID: bridge.bridgeID,
                conversationID: bridge.currentID,
                workspaceWindowID: bridge.window.map(ObjectIdentifier.init)) else {
            completeTransition(pendingTransition)
            return
        }

        switch pendingTransition.action {
        case .selectModel(let selection):
            confirmDownshiftThenSelect(selection, context: pendingTransition.context)
            completeTransition(pendingTransition)
        case .manageProviders:
            // Closing the popover restores focus to its workspace. Retire that newly active editor
            // too, and keep the whole control deck gated through the second quiet interval before
            // ordering the Providers utility window.
            deferredTransition = RemoteTextServiceSafety.deferWindowOrderSensitiveMutation(
                from: bridge.window
            ) {
                finishManageProviders(token: token)
            }
        }
    }

    /// Apply the selection, first confirming it when it costs this conversation its working context.
    ///
    /// Deliberately placed HERE, after `deferUntilWindowIsNoLongerVisible` has proven the picker
    /// window is offscreen, and never at the click. Presenting a sheet while the popover is still in
    /// the window hierarchy is the ordering that reproduced the NSRemoteView crash (FB23642313);
    /// this runs on the far side of that boundary, so the alert cannot re-enter it.
    private func confirmDownshiftThenSelect(
        _ selection: ModelSelection,
        context: DeferredModelSelectionContext
    ) {
        guard let warning = bridge.contextDownshiftWarning(for: selection) else {
            _ = bridge.selectModel(selection)
            return
        }
        guard let window = bridge.window else {
            // No window to host a sheet. Fail toward NOT silently shrinking the window: the user can
            // reopen the picker and choose again against a surface that can explain itself.
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        // `String(localized:)` rather than a bare literal: AppKit does no automatic localization, so
        // an alert set from a Swift literal can never be translated.
        alert.messageText = String(localized: "Switch to a smaller context window?")
        let current = AgentBridge.formattedTokenCount(warning.currentWindow)
        let next = AgentBridge.formattedTokenCount(warning.newWindow)
        let used = AgentBridge.formattedTokenCount(warning.contextTokens)
        alert.informativeText = String(
            localized: """
                \(warning.modelName) has a \(next)-token context window. This conversation is on a \
                \(current)-token window and is using \(used) tokens.

                Changing the model starts a fresh provider session, so this conversation continues \
                from a short summary rather than its full history, and it will summarize itself \
                again sooner in the smaller window.
                """)
        alert.addButton(withTitle: String(localized: "Switch Model"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            // The sheet is modal to one window, not to the app: another window could have switched
            // this workspace to a different conversation while it was up. Applying then would move
            // the model on whatever is showing now, which is the same class of bug the deferred
            // selection context was introduced to prevent.
            guard context.matches(
                bridgeID: bridge.bridgeID,
                conversationID: bridge.currentID,
                workspaceWindowID: bridge.window.map(ObjectIdentifier.init)) else { return }
            _ = bridge.selectModel(selection)
        }
    }

    private func finishManageProviders(token: UUID) {
        guard let pendingTransition,
              pendingTransition.token == token,
              pendingTransition.context.matches(
                bridgeID: bridge.bridgeID,
                conversationID: bridge.currentID,
                workspaceWindowID: bridge.window.map(ObjectIdentifier.init)),
              bridge.window?.isKeyWindow == true else {
            if let pendingTransition, pendingTransition.token == token {
                completeTransition(pendingTransition)
            }
            return
        }
        deferredTransition = nil
        showProviders(using: openWindow)
        completeTransition(pendingTransition)
    }

    private func completeTransition(_ transition: PendingTransition) {
        guard pendingTransition?.token == transition.token else { return }
        deferredTransition = nil
        pendingTransition = nil
        scheduleCleanup(for: transition.dismissedGeneration)
        isWindowOrderTransitioning = false
    }

    private func scheduleCleanup(for dismissedGeneration: UInt) {
        DispatchQueue.main.async {
            _ = presentation.clearPin(for: dismissedGeneration)
        }
    }
}

/// The conversation-level model control. Current provider catalogs remain authoritative for model
/// selection. A configured lane that needs authentication stays visible with its last reported
/// (non-selectable) catalog and an in-place Reconnect action.
struct ModelPickerView: View {
    @ObservedObject var bridge: AgentBridge
    @Binding var isPresented: Bool
    let onSelect: (ModelSelection, NSWindow?) -> Void
    let onManageProviders: (NSWindow?) -> Void
    /// Which row reads as current. Defaults to the conversation's model, which is right when the
    /// picker is choosing FOR a conversation and wrong everywhere else: the memory window picks a
    /// lane of its own, and showing the conversation's model as selected there tells a person their
    /// choice did not take.
    var currentSelection: ModelSelection?

    @ObservedObject private var catalogs = ModelCatalogStore.shared
    @ObservedObject private var accounts = ProviderAccountStore.shared

    @State private var search = ""
    @State private var capabilityFilter: String?
    @State private var highlightedSelection: ModelSelection?
    @State private var hoveredSelection: ModelSelection?
    @State private var blockedSelection: ModelSelection?
    @State private var pickerWindow: NSWindow?
    // The AppKit search field takes first responder via this counter; @FocusState only routes
    // between the SwiftUI rows (PickerSearchField.swift explains why the field is AppKit-backed).
    @State private var searchFocusRequest = 0
    @FocusState private var focus: FocusTarget?

    private enum FocusTarget: Hashable {
        case row(ModelSelection)
    }

    var body: some View {
        VStack(spacing: 0) {
            searchAndFilters
            Divider()
            if let blocker = activeSelectionBlocker {
                accessChangeBlockerBanner(blocker)
                Divider()
            }
            results
            Divider()
            footer
        }
        .frame(width: 420)
        .background(Color.nBg)
        .onAppear {
            bridge.prepareModelCatalogs(force: false)
            synchronizeFiltersAndHighlight()
            DispatchQueue.main.async { searchFocusRequest += 1 }
        }
        .onChange(of: search) { synchronizeHighlight() }
        .onChange(of: capabilityFilter) { synchronizeHighlight() }
        .onChange(of: catalogs.snapshots) { synchronizeFiltersAndHighlight() }
        .onChange(of: accounts.states) {
            bridge.prepareModelCatalogs(force: false)
            synchronizeFiltersAndHighlight()
        }
        .onMoveCommand(perform: moveHighlight)
        .onExitCommand { isPresented = false }
    }

    private var activeSelectionBlocker: ConversationAccessChangeBlocker? {
        guard let blockedSelection else { return nil }
        return bridge.modelSelectionBlocker(for: blockedSelection)
    }

    private func accessChangeBlockerBanner(
        _ blocker: ConversationAccessChangeBlocker
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(Color.nWarningText)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(blocker.pickerTitle)
                    .font(.caption.weight(.semibold))
                Text(blocker.pickerDetail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if blocker.canStopActiveWork {
                Button("Stop active work") {
                    bridge.stopConversationWork()
                }
                .buttonStyle(.plain)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.nInfoText)
                .accessibilityHint("Stops work only in this conversation")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color.orange.opacity(0.08))
        .accessibilityElement(children: .contain)
    }

    private var searchAndFilters: some View {
        VStack(spacing: 9) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                PickerSearchField(
                    text: $search,
                    placeholder: "Search models",
                    focusRequest: searchFocusRequest,
                    onSubmit: { chooseHighlighted() },
                    onMoveUp: { moveHighlight(.up) },
                    onMoveDown: { moveHighlight(.down) },
                    onCancel: { isPresented = false },
                    onWindowChange: { pickerWindow = $0 })
                    // The SwiftUI TextField this replaces was greedy; keep the field filling
                    // the capsule row rather than hugging its intrinsic width.
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !search.isEmpty {
                    Button {
                        search = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear search")
                    .accessibilityLabel("Clear model search")
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.nSurface)
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.nMuted.opacity(0.5))))

            HStack(spacing: 8) {
                if !capabilityOptions.isEmpty {
                    Menu {
                        Button {
                            capabilityFilter = nil
                        } label: {
                            if capabilityFilter == nil { Label("All capabilities", systemImage: "checkmark") }
                            else { Text("All capabilities") }
                        }
                        Divider()
                        ForEach(capabilityOptions, id: \.self) { capability in
                            Button {
                                capabilityFilter = capability
                            } label: {
                                if capabilityFilter == capability {
                                    Label(capabilityLabel(capability), systemImage: "checkmark")
                                } else {
                                    Text(capabilityLabel(capability))
                                }
                            }
                        }
                    } label: {
                        Label(capabilityFilter.map(capabilityLabel) ?? "Capabilities",
                              systemImage: "line.3.horizontal.decrease.circle")
                            .lineLimit(1)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(capabilityFilter == nil
                                             ? Color.nText.opacity(0.65) : Color.nAccent)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(
                                capabilityFilter == nil
                                    ? Color.nElevated.opacity(0.75)
                                    : Color.nAccent.opacity(0.14)))
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .accessibilityLabel("Capability filter")
                    .accessibilityValue(capabilityFilter.map(capabilityLabel) ?? "All capabilities")
                }

                Spacer(minLength: 4)
                Text("\(visibleEntries.count) model\(visibleEntries.count == 1 ? "" : "s")")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
                    .accessibilityLabel("\(visibleEntries.count) matching models")
            }
        }
        .padding(12)
        .background(Color.nSurface)
    }

    @ViewBuilder
    private var results: some View {
        if presentedAccesses.isEmpty {
            emptyState(
                icon: "person.crop.circle.badge.plus",
                title: "Connect an account to choose a model",
                detail: "Models appear here after their account is connected.",
                retry: false)
        } else if visibleMakers.isEmpty {
            emptyState(
                icon: "line.3.horizontal.decrease.circle",
                title: search.isEmpty ? "No models match these filters" : "No models match “\(search)”",
                detail: "Clear the search or filters to see the available catalog.",
                retry: false,
                clearFilters: true)
        } else {
            modelList
        }
    }

    private var modelList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // The catalog is deliberately small (normally fewer than twenty rows). A lazy
                // stack kept stale geometry when a last-known catalog was replaced in place by an
                // authoritative login probe, leaving a correctly-counted list visually blank until
                // the popover was reopened. Materializing these few rows makes that transition
                // deterministic and removes the stale-layout state entirely.
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(visibleMakers, id: \.rawValue) { maker in
                        makerSection(maker)
                    }
                    if catalogsAreLoading {
                        HStack(spacing: 7) {
                            ProgressView().controlSize(.small)
                            Text("Checking other connected accounts…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                    } else if !catalogErrors.isEmpty {
                        HStack(alignment: .firstTextBaseline, spacing: 7) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(Color.nWarningText)
                            Text("Some connected models could not be refreshed.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Retry") { bridge.prepareModelCatalogs(force: true) }
                                .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                    }
                }
                .padding(.vertical, 5)
            }
            .frame(height: 340)
            .onChange(of: highlightedSelection) { _, selection in
                guard let selection else { return }
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo(selection, anchor: .center)
                }
            }
        }
    }

    private func makerSection(_ maker: ModelMaker) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(makerLabel(maker))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.5)
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 5)
                .accessibilityAddTraits(.isHeader)

            ForEach(visibleAccesses(for: maker), id: \.self) { access in
                let operation = accounts.operation(for: access)
                let action = connectionAction(for: access)
                let entries = visibleEntries(for: access)
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 8) {
                        Text(access.displayName)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.tertiary)
                        Spacer()
                        if let operation {
                            ProgressView().controlSize(.mini)
                            Text(operation.progressLabel)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        } else if let action {
                            Text(accounts.state(for: access).statusLabel)
                                .font(.caption2)
                                .foregroundStyle(Color.nWarningText)
                            Button(action.label) { beginConnection(access) }
                                .buttonStyle(.plain)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(Color.nInfoText)
                                .accessibilityLabel("\(action.label) \(access.displayName)")
                        } else {
                            Text(accounts.state(for: access).statusLabel)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 4)
                        .accessibilityAddTraits(.isHeader)
                    ForEach(entries) { entry in
                        modelRow(entry)
                            .id(entry.selection)
                    }
                    if entries.isEmpty {
                        providerEmptyState(access, operation: operation, action: action)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func providerEmptyState(
        _ access: ModelAccess,
        operation: ProviderAccountStore.Operation?,
        action: ProviderAccountStore.SubscriptionConnectionAction?
    ) -> some View {
        let snapshot = catalogs.snapshot(for: access, scope: bridge.catalogScope(for: access))
        VStack(alignment: .leading, spacing: 6) {
            if let error = accounts.error(for: access) {
                Text(error)
                    .foregroundStyle(Color.nErrorText)
            } else if operation != nil {
                Text("Complete sign-in to load this provider's models.")
                    .foregroundStyle(.secondary)
            } else if let action {
                Text("\(action.label) \(access.displayName) to load its models.")
                    .foregroundStyle(.secondary)
            } else if eligibleAccesses.contains(access) {
                switch snapshot.phase {
                case .idle, .loading:
                    HStack(spacing: 7) {
                        ProgressView().controlSize(.mini)
                        Text("Checking available models…")
                            .foregroundStyle(.secondary)
                    }
                case .failed(let message):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(message)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Retry") { bridge.prepareModelCatalogs(force: true) }
                            .buttonStyle(.plain)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.nInfoText)
                    }
                case .ready:
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("This provider did not report any selectable models.")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Retry") { bridge.prepareModelCatalogs(force: true) }
                            .buttonStyle(.plain)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.nInfoText)
                    }
                }
            } else {
                Text(accounts.state(for: access).statusLabel)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private func modelRow(_ entry: ModelCatalogEntry) -> some View {
        let selected = isSelected(entry)
        let reconnectable = isReconnectable(entry.selection.access)
        let highlighted = entry.selection == highlightedSelection
            || entry.selection == hoveredSelection
        let summary = entrySummary(entry)
        let name = entry.versionedDisplayName
        // Two rows of the same family can differ by 5x in window and be otherwise indistinguishable
        // ("Opus 4.8" next to "Opus 4.8 (1M)"), which is a trap: picking the smaller one mid-project
        // silently costs the working context. The number belongs on the row, before the choice.
        let context = bridge.claudeContextWindow(for: entry)

        return Button {
            choose(entry)
        } label: {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(selected ? Color.nInfoText : Color.nText.opacity(0.45))
                    .frame(width: 13, height: 18)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text(name)
                            .font(.system(size: 13, weight: selected ? .semibold : .medium))
                            .foregroundStyle(Color.nText)
                            .lineLimit(1)
                        if entry.isDefault {
                            Text("Default")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        Spacer(minLength: 8)
                        if reconnectable {
                            Text("Last available")
                                .font(.caption2)
                                .foregroundStyle(Color.nWarningText)
                        }
                        if let context {
                            // Measured reads solid; a derivation reads faint. The tooltip says which
                            // outright, because "1M" as a guess and "1M" as an observation are
                            // different claims about someone's own deployment.
                            Text("\(AgentBridge.formattedTokenCount(context.window))")
                                .font(.caption2)
                                .monospacedDigit()
                                .foregroundStyle(context.isMeasured ? .secondary : .tertiary)
                                .lineLimit(1)
                        }
                        Text(entry.selection.access.displayName)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    if !summary.isEmpty {
                        Text(summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selected ? Color.nAccent.opacity(0.10)
                      : highlighted ? Color.nElevated.opacity(0.85) : Color.nSurface))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(focus == .row(entry.selection)
                              ? Color.nAccent.opacity(0.8) : Color.nMuted.opacity(0.35),
                              lineWidth: 1))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
        .opacity(reconnectable ? 0.68 : 1)
        .focused($focus, equals: .row(entry.selection))
        .onHover { hovering in
            hoveredSelection = hovering ? entry.selection
                : (hoveredSelection == entry.selection ? nil : hoveredSelection)
        }
        .accessibilityElement(children: .ignore)
        .help(reconnectable
              ? "Reconnect \(entry.selection.access.displayName) to use \(name)"
              : contextWindowHelp(name: name, context: context))
        .accessibilityLabel(accessibilityLabel(for: entry))
        .accessibilityValue(reconnectable ? "Disconnected, reconnect required"
                            : selected ? "Selected" : "")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// Says where the window number came from rather than leaving it to the badge's opacity.
    ///
    /// The distinction is not pedantic. A managed tenant profile can declare a model whose real
    /// window this build has no static knowledge of, so "as far as this build knows" and "this
    /// account was observed serving it" can disagree, and only the second is evidence about the
    /// user's own deployment.
    private func contextWindowHelp(
        name: String,
        context: (window: Int, isMeasured: Bool)?
    ) -> String {
        guard let context else { return "Use \(name)" }
        let size = AgentBridge.formattedTokenCount(context.window)
        return context.isMeasured
            ? "Use \(name). This account was measured serving a \(size)-token context window."
            : "Use \(name). Expected context window \(size) tokens, not yet confirmed on this "
                + "account; it is checked the first time a turn completes on this model."
    }

    private var footer: some View {
        HStack {
            if search.isEmpty && capabilityFilter == nil {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Connected models and configured providers are shown.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    // On a managed lane this list IS the configuration, so name the configuration
                    // that produced it. Without this, "my new model is missing" and "my update did
                    // not arrive" look identical from here, which cost a support round trip.
                    if let configuration = TenantProfile.currentConfigurationParts {
                        Group {
                            if let revision = configuration.revision {
                                Text("\(configuration.name) configuration · revision \(revision)")
                            } else {
                                Text("\(configuration.name) configuration")
                            }
                        }
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                        .help("The managed configuration these models come from. "
                              + "A published change that has not arrived shows an older revision.")
                        // Naming the revision is only half the truth: a local override replaces the
                        // published model list wholesale, so the revision above can be current while
                        // this list is not. Saying one without the other is what sent a tenant
                        // chasing a publish that had already landed.
                        if TenantProfile.currentModelsAreLocallyOverridden {
                            Text("This list was edited on this Mac, so it does not follow the "
                                 + "published configuration.")
                                .font(.caption2)
                                .foregroundStyle(Color.nWarningText)
                                .fixedSize(horizontal: false, vertical: true)
                                .help("Settings ▸ Managed Configuration ▸ Models ▸ Reset restores "
                                      + "the list your organization published.")
                        }
                    }
                }
            } else {
                Button("Clear Filters") { clearFilters() }
                    .buttonStyle(.plain)
                    .font(.caption)
            }
            Spacer()
            Button {
                onManageProviders(pickerWindow)
            } label: {
                Label("Manage Providers…", systemImage: "person.crop.circle")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .help("Open Providers")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.nSurface)
    }

    private func progressState(_ label: String) -> some View {
        VStack(spacing: 10) {
            ProgressView()
            Text(label).font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 220)
    }

    private func emptyState(
        icon: String,
        title: String,
        detail: String,
        retry: Bool,
        clearFilters: Bool = false
    ) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 26))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.callout.weight(.semibold))
                .multilineTextAlignment(.center)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 310)
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                if clearFilters {
                    Button("Clear Filters") { self.clearFilters() }
                        .buttonStyle(PillButtonStyle(kind: .plain))
                }
                if retry {
                    Button("Retry") { bridge.prepareModelCatalogs(force: true) }
                        .buttonStyle(PillButtonStyle(kind: .plain))
                }
            }
            .padding(.top, 3)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 220)
        .padding(.horizontal, 20)
    }

    // MARK: Catalog projection

    private var eligibleAccesses: [ModelAccess] {
        ModelAccess.selectableCases.filter { access in
            accounts.state(for: access).isAvailable && accounts.operation(for: access) == nil
        }
    }

    private var reconnectableAccesses: [ModelAccess] {
        ModelAccess.selectableCases.filter { access in
            accounts.operation(for: access) == nil && isReconnectable(access)
        }
    }

    private var presentedAccesses: [ModelAccess] {
        ModelAccess.selectableCases.filter { access in
            ModelPickerProviderPolicy.presents(access, state: accounts.state(for: access))
        }
    }

    private func isReconnectable(_ access: ModelAccess) -> Bool {
        connectionAction(for: access) != nil
    }

    private func connectionAction(
        for access: ModelAccess
    ) -> ProviderAccountStore.SubscriptionConnectionAction? {
        guard accounts.operation(for: access) == nil else { return nil }
        return ModelPickerProviderPolicy.connectionAction(
            for: access,
            state: accounts.state(for: access),
            requiresReconnect: bridge.providerNeedsReconnect(access),
            isEnvironmentManaged: accounts.isEnvironmentManaged(access))
    }

    private func beginConnection(_ access: ModelAccess) {
        bridge.connectOrReconnectAccount(access)
    }

    private var accountsAreChecking: Bool {
        !accounts.hasCompletedInitialCheck || ModelAccess.selectableCases.contains {
            accounts.state(for: $0) == .checking
        }
    }

    private var accountOperationInProgress: Bool {
        ModelAccess.selectableCases.contains { accounts.operation(for: $0) != nil }
    }

    private var scopedSnapshots: [(ModelAccess, ModelCatalogSnapshot)] {
        eligibleAccesses.map { access in
            (access, catalogs.snapshot(for: access, scope: bridge.catalogScope(for: access)))
        }
    }

    private var catalogsAreLoading: Bool {
        scopedSnapshots.contains { _, snapshot in
            snapshot.phase == .idle || snapshot.phase == .loading
        }
    }

    private var catalogErrors: [String] {
        scopedSnapshots.compactMap { _, snapshot in
            if case .failed(let message) = snapshot.phase { return message }
            return nil
        }
    }

    private var allEntries: [ModelCatalogEntry] {
        presentedAccesses.flatMap { access -> [ModelCatalogEntry] in
            let scope = bridge.catalogScope(for: access)
            let snapshot = catalogs.snapshot(for: access, scope: scope)
            let entries = ModelPickerCatalogProjection.entries(
                snapshot: snapshot,
                isEligible: eligibleAccesses.contains(access),
                isReconnectable: reconnectableAccesses.contains(access),
                hasAccountOperation: accounts.operation(for: access) != nil,
                fallbackEntries: AgentBridge.fallbackEntries(for: access, scope: scope),
                lastKnownEntries: catalogs.lastKnownEntries(for: access, scope: scope))
            return entries.filter { $0.selection.access == access }
        }
    }

    private var capabilityOptions: [String] {
        Set(allEntries.flatMap(\.capabilities)).sorted {
            capabilityLabel($0).localizedCaseInsensitiveCompare(capabilityLabel($1)) == .orderedAscending
        }
    }

    private var visibleEntries: [ModelCatalogEntry] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return allEntries.filter { entry in
            if let capabilityFilter, !entry.capabilities.contains(capabilityFilter) { return false }
            guard !query.isEmpty else { return true }
            return searchableText(entry).localizedCaseInsensitiveContains(query)
        }
    }

    private var visibleMakers: [ModelMaker] {
        [.anthropic, .openAI].filter { maker in
            visibleAccesses(for: maker).isEmpty == false
        }
    }

    private func visibleAccesses(for maker: ModelMaker) -> [ModelAccess] {
        presentedAccesses.filter { access in
            guard access.maker == maker else { return false }
            if visibleEntries.contains(where: { $0.selection.access == access }) { return true }
            guard access.usesInteractiveAccountFlow,
                  capabilityFilter == nil else { return false }
            let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
            let action = connectionAction(for: access)?.label ?? ""
            return query.isEmpty
                || "\(makerLabel(maker)) \(access.displayName) \(action) \(accounts.state(for: access).statusLabel)"
                .localizedCaseInsensitiveContains(query)
        }
    }

    private func visibleEntries(for access: ModelAccess) -> [ModelCatalogEntry] {
        visibleEntries.filter { $0.selection.access == access }
    }

    private func searchableText(_ entry: ModelCatalogEntry) -> String {
        ([entry.versionedDisplayName, entry.displayName, entry.selection.modelID,
          entry.resolvedModelID ?? "", entry.description,
          entry.selection.access.maker == .anthropic
            ? "Claude \(entry.versionedDisplayName)" : "",
          makerLabel(entry.selection.access.maker), entry.selection.access.displayName]
            + entry.capabilities.map(capabilityLabel)
            + entry.supportedEfforts.map {
                AgentBridge.effortLabel($0, access: entry.selection.access)
            })
            .joined(separator: " ")
    }

    private func entrySummary(_ entry: ModelCatalogEntry) -> String {
        let description = entry.description.trimmingCharacters(in: .whitespacesAndNewlines)
        if !description.isEmpty { return description }
        let capabilities = entry.capabilities.prefix(2).map(capabilityLabel)
        if !capabilities.isEmpty { return capabilities.joined(separator: " · ") }
        if !entry.supportedEfforts.isEmpty { return "Adjustable reasoning effort" }
        return ""
    }

    private func isSelected(_ entry: ModelCatalogEntry) -> Bool {
        let current = currentSelection ?? bridge.selectedModelSelection
        return entry.selection == current
            || (entry.selection.access == current.access
                && entry.resolvedModelID == current.modelID)
    }

    private func makerLabel(_ maker: ModelMaker) -> String {
        maker == .anthropic ? "Anthropic" : "OpenAI"
    }

    private func capabilityLabel(_ capability: String) -> String {
        switch capability {
        case "effort": return "Reasoning levels"
        case "adaptive_thinking": return "Adaptive reasoning"
        case "fast_mode": return "Fast mode"
        case "auto_mode": return "Automatic mode"
        default:
            return capability.replacingOccurrences(of: "_", with: " ")
                .split(separator: " ")
                .map { $0.prefix(1).uppercased() + $0.dropFirst() }
                .joined(separator: " ")
        }
    }

    private func accessibilityLabel(for entry: ModelCatalogEntry) -> String {
        var parts = [entry.versionedDisplayName, makerLabel(entry.selection.access.maker),
                     entry.selection.access.displayName]
        // The window badge is the one piece of row content VoiceOver would otherwise lose, and it
        // is the difference between two rows that are named almost identically.
        if let context = bridge.claudeContextWindow(for: entry) {
            let size = AgentBridge.formattedTokenCount(context.window)
            parts.append(context.isMeasured
                         ? "\(size) token context window, measured"
                         : "\(size) token context window, expected")
        }
        let summary = entrySummary(entry)
        if !summary.isEmpty { parts.append(summary) }
        return parts.joined(separator: ", ")
    }

    // MARK: Keyboard behavior

    private func moveHighlight(_ direction: MoveCommandDirection) {
        guard direction == .up || direction == .down, !visibleEntries.isEmpty else { return }
        let selections = visibleEntries.map(\.selection)
        let nextIndex: Int
        if let highlightedSelection,
           let index = selections.firstIndex(of: highlightedSelection) {
            nextIndex = direction == .down
                ? min(index + 1, selections.count - 1)
                : max(index - 1, 0)
        } else {
            nextIndex = direction == .down ? 0 : selections.count - 1
        }
        let selection = selections[nextIndex]
        highlightedSelection = selection
        focus = .row(selection)
    }

    private func chooseHighlighted() {
        let selection = highlightedSelection ?? visibleEntries.first?.selection
        guard let selection,
              let entry = visibleEntries.first(where: { $0.selection == selection }) else { return }
        choose(entry)
    }

    private func choose(_ entry: ModelCatalogEntry) {
        if isReconnectable(entry.selection.access) {
            bridge.reconnectAccount(entry.selection.access)
            return
        }
        applySelection(entry)
    }

    private func applySelection(_ entry: ModelCatalogEntry) {
        if bridge.modelSelectionBlocker(for: entry.selection) != nil {
            // Keep both the picker and its pending target in place. The banner explains the exact
            // blocker and, for live work, exposes the conversation-scoped recovery action.
            blockedSelection = entry.selection
            return
        }
        blockedSelection = nil
        // Clear SwiftUI's focused row. The button also retires the popover window's AppKit field
        // editor before publishing the provider change: disabling completion traits prevents new
        // suggestions but does not synchronously detach an already-created remote service view.
        focus = nil
        onSelect(entry.selection, pickerWindow)
    }

    private func synchronizeFiltersAndHighlight() {
        if let capabilityFilter, !capabilityOptions.contains(capabilityFilter) {
            self.capabilityFilter = nil
        }
        synchronizeHighlight()
    }

    private func synchronizeHighlight() {
        let selections = visibleEntries.map(\.selection)
        if let highlightedSelection, selections.contains(highlightedSelection) { return }
        highlightedSelection = visibleEntries.first(where: isSelected)?.selection ?? selections.first
    }

    private func clearFilters() {
        search = ""
        capabilityFilter = nil
        DispatchQueue.main.async { searchFocusRequest += 1 }
    }
}
