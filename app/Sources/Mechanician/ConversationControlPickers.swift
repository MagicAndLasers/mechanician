import SwiftUI

/// Presentation state must belong to one concrete control instance. `ContentView` can reflow that
/// instance between one- and two-row layouts as labels change; pinning its title while AppKit
/// dismisses the popover prevents a width change from moving the anchor during that transition.
struct ConversationControlPopoverState: Equatable {
    private(set) var isPresented = false
    private(set) var pinnedTitle: String?
    private(set) var generation: UInt = 0

    @discardableResult
    mutating func present(title: String) -> UInt {
        generation &+= 1
        pinnedTitle = title
        isPresented = true
        return generation
    }

    @discardableResult
    mutating func dismiss() -> UInt {
        isPresented = false
        return generation
    }

    /// Retire the native popover before a mutation that can reflow or replace its anchor.
    ///
    /// This must be a distinct operation rather than accepting the provider mutation as an
    /// argument. Swift evaluates arguments before entering a function, which previously let the
    /// provider change publish while `isPresented` was still true. SwiftUI then tried to show the
    /// same popover again during layout and macOS 27 aborted in ViewBridge.
    @discardableResult
    mutating func retireBeforeWindowOrderSensitiveMutation() -> UInt {
        dismiss()
    }

    /// Ignore a delayed cleanup from an older presentation if the control has already reopened.
    @discardableResult
    mutating func clearPin(for dismissedGeneration: UInt) -> Bool {
        guard !isPresented, generation == dismissedGeneration else { return false }
        pinnedTitle = nil
        return true
    }

    func triggerTitle(current: String, compact: Bool) -> String {
        compact ? "" : (pinnedTitle ?? current)
    }
}

/// A managed model declaration is immediately authoritative for selection, but it intentionally
/// carries no provider capability metadata. Opening the effort control is an explicit request for
/// that metadata, so it may bypass the declaration-only startup optimization exactly once per
/// provider catalog. An authoritative provider answer with no efforts must remain empty rather
/// than triggering an expensive probe every time the popover opens.
enum ConversationEffortCatalogPolicy {
    static func shouldRequestProviderRefresh(
        reportedEfforts: [String],
        hasProviderCatalog: Bool
    ) -> Bool {
        reportedEfforts.isEmpty && !hasProviderCatalog
    }
}

/// The reasoning control owns its popover lifecycle so toolbar reflow cannot re-present it.
/// Provider catalog refreshes are observed here, and a ready choice list remains stable while a
/// refresh is in flight.
struct ConversationEffortControl: View {
    @ObservedObject var bridge: AgentBridge
    var compact: Bool
    var wrapsTitle = false

    @ObservedObject private var catalogs = ModelCatalogStore.shared
    @ObservedObject private var accounts = ProviderAccountStore.shared
    @State private var presentation = ConversationControlPopoverState()
    @State private var presentedEfforts: [String] = []

    var body: some View {
        let reportedEfforts = bridge.availableEfforts
        let catalogScope = bridge.catalogScope(for: bridge.currentModelAccess)
        let catalogSnapshot = catalogs.snapshot(
            for: bridge.currentModelAccess, scope: catalogScope)
        let hasProviderCatalog = catalogs.hasProviderReportedCatalog(
            for: bridge.currentModelAccess, scope: catalogScope)
        let failureMessage: String? = if case .failed(let message) = catalogSnapshot.phase {
            message
        } else {
            nil
        }
        let needsProviderRefresh = ConversationEffortCatalogPolicy.shouldRequestProviderRefresh(
            reportedEfforts: reportedEfforts,
            hasProviderCatalog: hasProviderCatalog)
        let currentTitle = AgentBridge.effortLabel(
            bridge.effortSelectionID, access: bridge.currentModelAccess)
        let visibleEfforts = presentation.isPresented && !presentedEfforts.isEmpty
            ? presentedEfforts
            : reportedEfforts
        let emptyFooter = failureMessage.map { "Couldn’t load levels: \($0)" }
            ?? (needsProviderRefresh
                ? "Loading levels reported by \(bridge.currentModelAccess.displayName)…"
                : "\(bridge.currentModelAccess.displayName) reported no adjustable levels for the selected model.")

        Button {
            presentedEfforts = reportedEfforts
            presentation.present(title: currentTitle)
            // A ready catalog must remain untouched while its popover is anchored. Forcing a
            // refresh replaces its snapshot with `.loading`, which can cause AppKit to dismiss
            // the popover during the corresponding SwiftUI layout pass. Only start discovery
            // when this selected model has not reported its choices yet.
            if needsProviderRefresh, failureMessage == nil {
                DispatchQueue.main.async {
                    bridge.prepareCurrentModelCatalog(force: true)
                }
            }
        } label: {
            MechanicianControlTrigger(
                title: presentation.triggerTitle(current: currentTitle, compact: compact),
                systemImage: "speedometer",
                showsChevron: true,
                maxTitleWidth: wrapsTitle ? 76 : nil,
                wrapsTitle: wrapsTitle)
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help(reportedEfforts.isEmpty
            ? (needsProviderRefresh
                ? "Load reasoning effort levels"
                : "No adjustable reasoning effort reported")
            : "Reasoning effort")
        .accessibilityLabel("Reasoning effort")
        .accessibilityValue(reportedEfforts.isEmpty
            ? (needsProviderRefresh
                ? "Loading provider levels; current preference \(currentTitle)"
                : "Provider reported no adjustable levels; current preference \(currentTitle)")
            : currentTitle)
        .popover(isPresented: presentedBinding(currentTitle: currentTitle), arrowEdge: .bottom) {
            MechanicianControlChoicePopover(
                title: "Reasoning effort",
                choices: visibleEfforts.map {
                    MechanicianControlChoice(
                        id: $0,
                        title: AgentBridge.effortLabel(
                            $0, access: bridge.currentModelAccess),
                        detail: AgentBridge.effortDescription(
                            $0, access: bridge.currentModelAccess))
                },
                selectedID: bridge.effortSelectionID,
                footer: visibleEfforts.isEmpty
                    ? emptyFooter
                    : "Levels reported by \(bridge.currentModelAccess.displayName) for the selected model.",
                footerActionTitle: failureMessage == nil ? nil : "Retry",
                onFooterAction: failureMessage == nil ? nil : {
                    bridge.prepareCurrentModelCatalog(force: true)
                }) { choice in
                    selectEffort(choice.id)
                }
        }
        .onChange(of: accounts.states) {
            // The first click can race Vertex's asynchronous ADC verification. Match the model
            // picker's self-healing behavior instead of requiring the user to open another control.
            let efforts = bridge.availableEfforts
            let providerCatalogLoaded = catalogs.hasProviderReportedCatalog(
                for: bridge.currentModelAccess,
                scope: bridge.catalogScope(for: bridge.currentModelAccess))
            if presentation.isPresented,
               ConversationEffortCatalogPolicy.shouldRequestProviderRefresh(
                reportedEfforts: efforts,
                hasProviderCatalog: providerCatalogLoaded) {
                bridge.prepareCurrentModelCatalog(force: true)
            }
        }
    }

    private func presentedBinding(currentTitle: String) -> Binding<Bool> {
        Binding(
            get: { presentation.isPresented },
            set: { presented in
                if presented {
                    if !presentation.isPresented {
                        presentation.present(title: currentTitle)
                    }
                } else {
                    scheduleCleanup(for: presentation.dismiss())
                }
            })
    }

    private func selectEffort(_ effort: String) {
        let dismissedGeneration = presentation.dismiss()
        // Keep the old-width title pinned while SwiftUI closes the popover. Apply the provider
        // preference on the next pass, then release the pin only after another pass has completed.
        DispatchQueue.main.async {
            if effort == "ultra" {
                // Codex Ultra is the orchestration flag surfaced as a level; route it through the
                // same setter the Claude pill uses so the wire mapping stays provider-native.
                bridge.setUltra(true)
            } else {
                bridge.effort = effort
            }
            scheduleCleanup(for: dismissedGeneration)
        }
    }

    private func scheduleCleanup(for dismissedGeneration: UInt) {
        DispatchQueue.main.async {
            if presentation.clearPin(for: dismissedGeneration) {
                presentedEfforts = []
            }
        }
    }
}

/// Permissions used the same shared parent binding as Effort and had the same latent re-presentation
/// failure when its label changed. Keep it instance-owned and defer the width-changing mutation too.
enum ConversationPermissionTriggerPresentation {
    static func badge(appliesNextTurn: Bool, compact: Bool) -> String? {
        appliesNextTurn && !compact ? "NEXT" : nil
    }
}

struct ConversationPermissionControl: View {
    @ObservedObject var bridge: AgentBridge
    var compact: Bool
    var wrapsTitle = false

    @State private var presentation = ConversationControlPopoverState()

    var body: some View {
        let option = PermissionPresentation.option(
            mode: bridge.permissionMode,
            access: bridge.currentModelAccess)

        Button {
            presentation.present(title: option.title)
        } label: {
            MechanicianControlTrigger(
                title: presentation.triggerTitle(current: option.title, compact: compact),
                systemImage: "shield",
                showsChevron: true,
                active: bridge.permissionModeAppliesNextTurn,
                maxTitleWidth: wrapsTitle ? 110 : nil,
                badge: ConversationPermissionTriggerPresentation.badge(
                    appliesNextTurn: bridge.permissionModeAppliesNextTurn,
                    compact: compact),
                wrapsTitle: wrapsTitle)
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help(option.detail)
        .accessibilityLabel("Permissions")
        .accessibilityValue(option.title)
        .popover(isPresented: presentedBinding(currentTitle: option.title), arrowEdge: .bottom) {
            MechanicianControlChoicePopover(
                title: "Permissions",
                choices: PermissionPresentation.options(for: bridge.currentModelAccess)
                    .map {
                        MechanicianControlChoice(
                            id: $0.mode,
                            title: $0.title,
                            detail: $0.detail)
                    },
                selectedID: bridge.permissionMode,
                footer: permissionFooter) { choice in
                    selectPermission(choice.id)
                }
        }
    }

    private func presentedBinding(currentTitle: String) -> Binding<Bool> {
        Binding(
            get: { presentation.isPresented },
            set: { presented in
                if presented {
                    if !presentation.isPresented {
                        presentation.present(title: currentTitle)
                    }
                } else {
                    scheduleCleanup(for: presentation.dismiss())
                }
            })
    }

    private func selectPermission(_ mode: String) {
        let dismissedGeneration = presentation.dismiss()
        DispatchQueue.main.async {
            bridge.permissionMode = mode
            scheduleCleanup(for: dismissedGeneration)
        }
    }

    private func scheduleCleanup(for dismissedGeneration: UInt) {
        DispatchQueue.main.async {
            _ = presentation.clearPin(for: dismissedGeneration)
        }
    }

    private var permissionFooter: String {
        guard let active = bridge.activePermissionMode else {
            return "Applies when the next turn starts for this conversation's provider and workspace."
        }
        let current = PermissionPresentation.option(
            mode: active,
            access: bridge.currentModelAccess).title
        let next = PermissionPresentation.option(
            mode: bridge.permissionMode,
            access: bridge.currentModelAccess).title
        if active == bridge.permissionMode {
            return "This turn is using \(current). Choose another mode now to apply it to the next turn."
        }
        return "Current turn: \(current). Next turn: \(next)."
    }
}
