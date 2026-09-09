import SwiftUI

enum HelpSidebarIconForegroundPolicy: Equatable {
    case inherited
    case info
}

func helpSidebarIconForegroundPolicy(isSelected: Bool) -> HelpSidebarIconForegroundPolicy {
    isSelected ? .inherited : .info
}

enum HelpSelection: Hashable {
    case article(String)
    case searchResult(String)
    case liveInventory
}

enum HelpSearchNavigationOutcome: Equatable {
    case searching
    case results([String])
    case empty
    case failed
}

/// Pure navigation state for the reader. Search results are transient selections; clearing Search
/// restores the catalog topic (or live inventory) the user was reading before Search took over.
struct HelpReaderNavigationState: Equatable {
    private(set) var selection: HelpSelection?
    private var selectionBeforeSearch: HelpSelection?
    private var staysAtCatalogRoot = false

    init(selection: HelpSelection? = nil) {
        self.selection = selection
    }

    mutating func select(_ selection: HelpSelection?) {
        self.selection = selection
        switch selection {
        case .none:
            staysAtCatalogRoot = true
        case .article, .liveInventory:
            staysAtCatalogRoot = false
        case .searchResult:
            // Preserve whether Search began at the catalog or a durable topic. Clearing the query
            // should return to that place, not treat a transient result as a new durable origin.
            break
        }
    }

    mutating func corpusBecameReady(firstArticleID: String?, queryIsEmpty: Bool) {
        // A pending search can finish in the same SwiftUI update as corpus loading. Do not let the
        // load transition erase the result selection whichever onChange callback runs first.
        guard queryIsEmpty else { return }
        if selection == nil, !staysAtCatalogRoot, let firstArticleID {
            selection = .article(firstArticleID)
        }
    }

    mutating func corpusBecameUnavailable() {
        selection = nil
        selectionBeforeSearch = nil
        staysAtCatalogRoot = false
    }

    mutating func queryChanged(
        wasEmpty: Bool,
        isEmpty: Bool,
        firstArticleID: String?
    ) {
        switch (wasEmpty, isEmpty) {
        case (true, false):
            selectionBeforeSearch = selection
            selection = nil
        case (false, true):
            selection = selectionBeforeSearch
                ?? (staysAtCatalogRoot ? nil : firstArticleID.map(HelpSelection.article))
            selectionBeforeSearch = nil
        case (false, false):
            selection = nil
        case (true, true):
            break
        }
    }

    mutating func searchRestarted() {
        selection = nil
    }

    /// An explicit reader-home action differs from the initial load: once a person asks for the
    /// catalog, a ready-state refresh or the query-cleared callback must not immediately reopen the
    /// first article and hide the catalog again at compact width.
    mutating func returnToCatalog() {
        selection = nil
        selectionBeforeSearch = nil
        staysAtCatalogRoot = true
    }

    mutating func reconcileSearch(
        _ outcome: HelpSearchNavigationOutcome,
        queryIsEmpty: Bool,
        automaticallySelectFirstResult: Bool = true
    ) {
        guard !queryIsEmpty else { return }
        switch outcome {
        case .results(let ids):
            guard let first = ids.first else {
                selection = nil
                return
            }
            if case let .searchResult(selectedID) = selection,
               ids.contains(selectedID) {
                return
            }
            guard automaticallySelectFirstResult else {
                selection = nil
                return
            }
            selection = .searchResult(first)
        case .searching, .empty, .failed:
            selection = nil
        }
    }
}

func helpLifecycleLabel(_ lifecycle: MechanicianHelpLifecycle) -> String {
    switch lifecycle {
    case .current: "Current"
    case .historical: "Historical"
    case .superseded: "Superseded"
    case .retired: "Retired"
    }
}

func helpEvidenceKindLabel(_ kind: MechanicianHelpEvidenceKind) -> String {
    switch kind {
    case .source: "Source"
    case .test: "Test"
    case .architecture: "Architecture"
    case .canonicalDoc: "Canonical document"
    case .release: "Release"
    case .history: "History"
    }
}

func helpLiveInventoryIsVisible(allowsLiveInventory: Bool) -> Bool {
    allowsLiveInventory
}

/// Recovery Help is a signed, reader-only surface. Opening an ordinary Workspace constructs live
/// product stores, so the expert handoff appears only after launch authority admits product actions.
func helpAgentWorkspaceIsAvailable(allowsProductActions: Bool) -> Bool {
    allowsProductActions
}

func helpDemonstrationIsAvailable(
    _ demonstration: MechanicianHelpDemonstration,
    allowsProductActions: Bool
) -> Bool {
    allowsProductActions && demonstration.lifecycle == .current
}

/// Builds the reviewable request that a Help demonstration places in a new composer. The recipe
/// remains data: the live conversation must explain it, check its own tools, obtain the ordinary
/// approvals, and verify the observed result before it can claim success.
func helpDemonstrationDraftPrompt(
    for demonstration: MechanicianHelpDemonstration
) -> String {
    var lines = [
        String(localized: "Mechanician Help demonstration request"),
        helpDemonstrationPromptField(
            String(localized: "Recipe:"),
            value: demonstration.id),
        helpDemonstrationPromptField(
            String(localized: "Title:"),
            value: demonstration.title),
        helpDemonstrationPromptField(
            String(localized: "Visible outcome:"),
            value: demonstration.outcome),
        "",
        String(localized: "Before using tools"),
        String(localized: "- Explain the demonstration plan before calling any tool. State the exact visible outcome, the tools you intend to use, what may change, how you will verify it, and the reviewed cleanup or fallback."),
        String(localized: "- Then check the live tool inventory available to this exact conversation. Do not rely on Help’s general inventory, another conversation, or a different provider route."),
        String(localized: "- If any required tool or mode is unavailable here, stop and use the applicable reviewed fallback. Do not improvise a substitute tool."),
        "",
        String(localized: "Requirements"),
        helpDemonstrationPromptField(
            String(localized: "Session:"),
            value: helpDemonstrationSessionLabel(demonstration.requirements.session)),
        helpDemonstrationPromptField(
            String(localized: "Mode:"),
            value: helpDemonstrationModeLabel(demonstration.requirements.mode)),
        helpDemonstrationPromptField(
            String(localized: "Required tools:"),
            value: demonstration.requirements.tools.isEmpty
                ? String(localized: "None")
                : demonstration.requirements.tools.joined(separator: ", ")),
        helpDemonstrationPromptField(
            String(localized: "Risk:"),
            value: helpDemonstrationRiskLabel(demonstration.risk)),
        helpDemonstrationPromptField(
            String(localized: "User confirmation:"),
            value: helpDemonstrationConfirmationLabel(demonstration.userConfirmation)),
        "",
        String(localized: "Reviewed steps"),
    ]

    for (index, step) in demonstration.steps.enumerated() {
        lines.append(
            String.localizedStringWithFormat(
                String(localized: "%1$lld. [%2$@] %3$@"),
                Int64(index + 1),
                helpDemonstrationStepKindLabel(step.kind),
                step.instruction))
        lines.append(helpDemonstrationPromptField(String(localized: "Step ID:"), value: step.id))
        if let tool = step.tool {
            lines.append(helpDemonstrationPromptField(String(localized: "Tool:"), value: tool))
        }
    }

    lines.append("")
    lines.append(String(localized: "Verification"))
    for item in demonstration.verification {
        lines.append(
            helpDemonstrationPromptField(
                String(localized: "Verification rule:"),
                value: helpDemonstrationVerificationLabel(item.kind)))
        lines.append(helpDemonstrationPromptField(String(localized: "Verify step:"), value: item.stepID))
        lines.append(item.instruction)
    }

    lines.append("")
    lines.append(String(localized: "Cleanup and reversibility"))
    lines.append(
        helpDemonstrationPromptField(
            String(localized: "Reversibility:"),
            value: helpDemonstrationReversibilityLabel(demonstration.reversibility.kind)))
    lines.append(demonstration.reversibility.instructions)
    lines.append(String(localized: "Verify the observed result before performing cleanup or claiming success. Apply only the cleanup described above; do not invent or promise an undo."))

    lines.append("")
    lines.append(String(localized: "Reviewed fallbacks"))
    if demonstration.fallback.isEmpty {
        lines.append(String(localized: "No fallback is defined. Stop and explain the failure."))
    } else {
        for item in demonstration.fallback {
            lines.append(
                helpDemonstrationPromptField(
                    String(localized: "When:"),
                    value: helpDemonstrationFallbackWhenLabel(item.when)))
            lines.append(
                helpDemonstrationPromptField(
                    String(localized: "Fallback action:"),
                    value: helpDemonstrationFallbackActionLabel(item.action)))
            if let demoID = item.demoID {
                lines.append(
                    helpDemonstrationPromptField(
                        String(localized: "Fallback Help demonstration:"),
                        value: demoID))
            }
            lines.append(item.instruction)
            if item.action == .useDemo {
                lines.append(String(localized: "This reference is not an executable recipe. Stop using tools and do not reconstruct, improvise, or run the fallback from its ID or the note above. Explain that this demonstration cannot continue, then ask the user to return to Mechanician Help and choose Try workflow for the named fallback demonstration. Only the separate reviewed draft created by Help may continue it."))
            }
        }
    }

    lines.append("")
    lines.append(String(localized: "Non-negotiable boundaries"))
    lines.append(String(localized: "- This request grants no app approval or macOS permission. Never bypass, suppress, or assume either one; an approval may still be required in any mode."))
    lines.append(String(localized: "- Do not send messages, make purchases, delete data, change privacy or security settings, or create scheduled, delegated, or otherwise unattended work."))
    lines.append(String(localized: "- Stay within the visible outcome and reviewed steps. Do not expand the task merely because another tool is available."))
    lines.append(String(localized: "- Work in this order: explain; call RecommendMechanicianWorkflow with the goal above and demonstrationID exactly \(demonstration.id); obtain any required confirmation and approvals; follow the reviewed steps; verify the observed result; then perform the reviewed cleanup or fallback."))
    lines.append(String(localized: "- Continue only if the returned workflow ID exactly matches \(demonstration.id) and its app-owned readiness label is Ready to try here. For Switch out of Plan, Not available in this conversation, or Not verified yet, stop and follow the returned next action or this recipe’s reviewed fallback."))
    lines.append(String(localized: "- A readiness label is advice, never authorization. Tool presence does not prove live resources, approval, macOS permission, effects, or success."))
    switch demonstration.userConfirmation {
    case .beforeDemo:
        lines.append(String(localized: "- Sending this reviewed request confirms only the named additive in-app demonstration after you explain it. It does not approve a broader or different action."))
    case .beforeAct:
        lines.append(String(localized: "- Sending this request is not confirmation to act. First inspect the available choices, state the exact selected action and arguments, and obtain fresh user confirmation immediately before calling the action tool."))
    case .none:
        break
    }
    lines.append(String(localized: "- If an action, approval, or verification fails, report that result plainly and follow only the applicable reviewed fallback. Never infer success from intent."))

    return lines.joined(separator: "\n")
}

/// Recovery Help and non-current recipes cannot construct an actionable handoff. Eligible recipes
/// can only construct the route that fills a composer; the sending route is intentionally absent.
func helpDemonstrationDraftRoute(
    for demonstration: MechanicianHelpDemonstration,
    allowsProductActions: Bool
) -> MechanicianRoute? {
    guard helpDemonstrationIsAvailable(
        demonstration,
        allowsProductActions: allowsProductActions)
    else { return nil }
    return .newStandardConversationDraft(helpDemonstrationDraftPrompt(for: demonstration))
}

private func helpDemonstrationPromptField(_ label: String, value: String) -> String {
    "\(label) \(value)"
}

private func helpDemonstrationRiskLabel(_ risk: MechanicianHelpDemoRisk) -> String {
    switch risk {
    case .readOnly: String(localized: "Read only")
    case .sensitiveRead: String(localized: "Sensitive read")
    case .reversibleLocal: String(localized: "Reversible local change")
    case .additive: String(localized: "Additive change")
    case .destructive: String(localized: "Destructive")
    case .dynamic: String(localized: "Depends on the selected action")
    }
}

private func helpDemonstrationReversibilityLabel(
    _ kind: MechanicianHelpDemoReversibilityKind
) -> String {
    switch kind {
    case .notNeeded: String(localized: "Not needed")
    case .automatic: String(localized: "Automatic")
    case .manual: String(localized: "Manual")
    case .notGuaranteed: String(localized: "Not guaranteed")
    case .dynamic: String(localized: "Depends on the selected action")
    }
}

private func helpDemonstrationConfirmationLabel(
    _ confirmation: MechanicianHelpDemoConfirmation
) -> String {
    switch confirmation {
    case .none: String(localized: "No additional confirmation")
    case .beforeDemo: String(localized: "Before starting the demonstration")
    case .beforeAct: String(localized: "Before acting")
    }
}

private func helpDemonstrationSessionLabel(_ session: MechanicianHelpDemoSession) -> String {
    switch session {
    case .interactive: String(localized: "Interactive conversation only")
    }
}

private func helpDemonstrationModeLabel(_ mode: MechanicianHelpDemoMode) -> String {
    switch mode {
    case .readOnlyOkay: String(localized: "Read-only mode is sufficient")
    case .planCompatibleAction: String(localized: "Available in Plan and execution modes")
    case .executionEnabled: String(localized: "Tool execution must be enabled")
    }
}

private func helpDemonstrationStepKindLabel(_ kind: MechanicianHelpDemoStepKind) -> String {
    switch kind {
    case .observe: String(localized: "Observe")
    case .ask: String(localized: "Ask")
    case .act: String(localized: "Act")
    case .explain: String(localized: "Explain")
    }
}

private func helpDemonstrationVerificationLabel(
    _ kind: MechanicianHelpDemoVerificationKind
) -> String {
    switch kind {
    case .toolSucceeded: String(localized: "Tool succeeded")
    case .visualState: String(localized: "Visible state changed as expected")
    case .userObserved: String(localized: "User observed the result")
    }
}

private func helpDemonstrationFallbackWhenLabel(
    _ condition: MechanicianHelpDemoFallbackWhen
) -> String {
    switch condition {
    case .toolUnavailable: String(localized: "A required tool is unavailable")
    case .emptyResult: String(localized: "The result is empty")
    case .permissionDenied: String(localized: "Permission is denied")
    case .actionFailed: String(localized: "The action fails")
    case .verificationFailed: String(localized: "Verification fails")
    }
}

private func helpDemonstrationFallbackActionLabel(
    _ action: MechanicianHelpDemoFallbackAction
) -> String {
    switch action {
    case .explain: String(localized: "Explain and stop")
    case .useDemo: String(localized: "Stop and ask the user to launch the named Help demonstration")
    }
}

/// One reader, with product actions admitted explicitly by the surface that hosts it.
///
/// The standalone Help window can show the active conversation's inventory and open the Help
/// expert. The Help workspace is already that expert, so its inspector hides both self-referential
/// surfaces while retaining reviewed workflow handoffs into an ordinary conversation. Recovery
/// Help admits none of the product-store or action paths.
enum HelpBrowserHost: Equatable {
    case standalone(allowsProductActions: Bool)
    case workspaceInspector

    var showsLiveInventory: Bool {
        guard case .standalone(let allowsProductActions) = self else { return false }
        return allowsProductActions
    }

    var showsExpertHandoff: Bool {
        guard case .standalone(let allowsProductActions) = self else { return false }
        return allowsProductActions
    }

    var allowsDemonstrations: Bool {
        switch self {
        case .standalone(let allowsProductActions): allowsProductActions
        case .workspaceInspector: true
        }
    }

    /// Native tours are owned by the exact Help workspace window. They never appear in the
    /// standalone/recovery reader, and an ordinary workspace that opts into the Help tab has no
    /// coordinator with which to start one.
    var allowsGuides: Bool {
        self == .workspaceInspector
    }

    var sidebarWidths: (minimum: CGFloat, ideal: CGFloat, maximum: CGFloat) {
        switch self {
        case .standalone: (235, 275, 350)
        case .workspaceInspector: (180, 200, 240)
        }
    }
}

enum HelpBrowserLayout: Equatable {
    case split
    case compact
}

/// The container that is allowed to render one Help reader layout.
///
/// `NavigationSplitView` is appropriate for the standalone Help window because that reader owns
/// its window. It must never be mounted inside a workspace inspector: on macOS its sidebar is
/// promoted into window-level navigation chrome and can paint above the inspector's own tab bar.
/// The inspector therefore owns an ordinary, explicitly budgeted pair of columns instead.
enum HelpBrowserContainer: Equatable {
    case nativeNavigationSplit
    case boundedInspectorSplit
    case compactInspector
}

/// Exact horizontal budget for the inspector's bounded two-column reader.
///
/// Keep the topic column at its existing ideal width while clamping it to the host's reviewed
/// minimum/maximum. The detail receives every remaining point, including at the exact responsive
/// boundary, so neither child can export a larger intrinsic width into the conversation column.
struct HelpInspectorSplitLayout: Equatable {
    static let dividerWidth: CGFloat = 1

    let containerWidth: CGFloat
    let sidebarWidth: CGFloat
    let dividerWidth: CGFloat
    let detailWidth: CGFloat

    var allocatedWidth: CGFloat {
        sidebarWidth + dividerWidth + detailWidth
    }

    init(width: CGFloat, sidebarWidths: (minimum: CGFloat, ideal: CGFloat, maximum: CGFloat)) {
        containerWidth = max(0, width)
        dividerWidth = min(Self.dividerWidth, containerWidth)
        let availableForSidebar = max(0, containerWidth - dividerWidth)
        let reviewedIdeal = min(
            max(sidebarWidths.ideal, sidebarWidths.minimum),
            sidebarWidths.maximum)
        sidebarWidth = min(reviewedIdeal, availableForSidebar)
        detailWidth = max(0, containerWidth - sidebarWidth - dividerWidth)
    }
}

enum HelpGuideArticleScrollTarget: String, Equatable {
    case content = "help.guide.article.content"
    case evidence = "help.guide.article.evidence"
    case demonstrations = "help.guide.article.demonstrations"
}

enum HelpGuideRevealDestination: Equatable {
    case unchanged
    case topics
    case article(HelpGuideArticleScrollTarget)
}

func helpGuideRevealDestination(
    for action: MechanicianHelpGuideRevealAction
) -> HelpGuideRevealDestination {
    switch action {
    case .none, .showHelpInspector, .showFilesInspector, .showChangesInspector, .showArtifactsInspector,
         .showAgentsInspector, .showSkillsInspector, .showConversationControls:
        .unchanged
    case .showHelpTopics:
        .topics
    case .showGuideArticle:
        .article(.content)
    case .showGuideEvidence:
        .article(.evidence)
    case .showGuideDemonstrations:
        .article(.demonstrations)
    }
}

/// Tracks only the topic/catalog selection the native guide owns. A click or search made by the
/// person revokes restoration, so Exit never overwrites a later choice. Version 1 deliberately
/// does not claim or attempt to restore an arbitrary article scroll offset.
@MainActor
final class HelpGuideReaderSession {
    let initialNavigation: HelpReaderNavigationState
    private(set) var expectedSelection: HelpSelection?
    private(set) var userChangedReader = false

    init(navigation: HelpReaderNavigationState) {
        initialNavigation = navigation
        expectedSelection = navigation.selection
    }

    func expect(selection: HelpSelection?) {
        expectedSelection = selection
    }

    func observe(selection: HelpSelection?) {
        if selection != expectedSelection { userChangedReader = true }
    }

    func observe(query: String, includeHistory: Bool) {
        if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || includeHistory {
            userChangedReader = true
        }
    }

    var canRestore: Bool { !userChangedReader }
}

/// Whether the reader may offer its own **Start tour** control for this guide.
///
/// The reader can only present a guide whose controls live in the window it is running in. A
/// conversation guide points at the inspector tabs and composer controls of a workspace window, so
/// offering Start tour here would install an overlay that stalls on its first step with "this
/// step's control isn't available in this window" and can never recover. Those guides are the
/// agent's to present through `ShowMechanician`, which resolves a real destination window first.
func helpGuideIsAvailable(
    _ guide: MechanicianHelpGuide,
    host: HelpBrowserHost,
    hasExactCoordinator: Bool
) -> Bool {
    host.allowsGuides
        && hasExactCoordinator
        && guide.lifecycle == .current
        && guide.surface == .helpWorkspaceInspector
}

func helpBrowserLayout(width: CGFloat, host: HelpBrowserHost) -> HelpBrowserLayout {
    switch helpBrowserContainer(width: width, host: host) {
    case .compactInspector:
        .compact
    case .nativeNavigationSplit, .boundedInspectorSplit:
        .split
    }
}

func helpBrowserContainer(width: CGFloat, host: HelpBrowserHost) -> HelpBrowserContainer {
    guard host == .workspaceInspector else { return .nativeNavigationSplit }
    return width < 440 ? .compactInspector : .boundedInspectorSplit
}

/// History is a search modifier, not durable reader state. Keeping it enabled after the query is
/// cleared would leave an invisible filter that also makes current-only reader actions appear to
/// vanish. Manual deletion and the clear button therefore converge on the same visible state.
func helpHistorySelection(query: String, currentValue: Bool) -> Bool {
    query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        ? false
        : currentValue
}

enum HelpInspectorTabActivationPolicy {
    static func shouldReturnToCatalog(
        activation: InspectorTabUserActivation?
    ) -> Bool {
        activation?.tab == .help
    }
}

/// The utility-window host. It keeps the large standalone geometry and recovery-safe admission,
/// while the actual reader below is shared with the Help workspace inspector.
@MainActor
struct HelpWindowView: View {
    @StateObject private var library: HelpLibrary
    private let allowsLiveInventory: Bool
    private let openDemonstrationRoute: @MainActor (MechanicianRoute) -> Void
    private let openHelpWorkspaceAction: @MainActor () -> Void

    init(
        allowsLiveInventory: Bool = true,
        openDemonstrationRoute: @escaping @MainActor (MechanicianRoute) -> Void = {
            _ = ActiveWorkspace.shared.open($0)
        },
        openHelpWorkspaceAction: @escaping @MainActor () -> Void = {
            openHelpWorkspace()
        }
    ) {
        self.allowsLiveInventory = allowsLiveInventory
        self.openDemonstrationRoute = openDemonstrationRoute
        self.openHelpWorkspaceAction = openHelpWorkspaceAction
        _library = StateObject(wrappedValue: HelpLibrary())
    }

    init(
        library: HelpLibrary,
        allowsLiveInventory: Bool = true,
        openDemonstrationRoute: @escaping @MainActor (MechanicianRoute) -> Void = {
            _ = ActiveWorkspace.shared.open($0)
        },
        openHelpWorkspaceAction: @escaping @MainActor () -> Void = {
            openHelpWorkspace()
        }
    ) {
        self.allowsLiveInventory = allowsLiveInventory
        self.openDemonstrationRoute = openDemonstrationRoute
        self.openHelpWorkspaceAction = openHelpWorkspaceAction
        _library = StateObject(wrappedValue: library)
    }

    var body: some View {
        HelpBrowserView(
            library: library,
            host: .standalone(allowsProductActions: allowsLiveInventory),
            openDemonstrationRoute: openDemonstrationRoute,
            openHelpWorkspaceAction: openHelpWorkspaceAction)
        .frame(minWidth: 900, minHeight: 590)
    }
}

/// The signed Help record beside a closed Help conversation. Browsing never changes the provider
/// context. Re-pressing the visible Help tab returns the reader to its catalog without reacting to
/// automatic tab restoration.
@MainActor
struct HelpInspectorView: View {
    @EnvironmentObject private var bridge: AgentBridge
    @StateObject private var library: HelpLibrary
    private let guideCoordinator: GuidedHelpPresentationCoordinator?
    private let openDemonstrationRoute: @MainActor (MechanicianRoute) -> Void

    init(
        guideCoordinator: GuidedHelpPresentationCoordinator? = nil,
        openDemonstrationRoute: @escaping @MainActor (MechanicianRoute) -> Void = {
            _ = ActiveWorkspace.shared.open($0)
        }
    ) {
        self.guideCoordinator = guideCoordinator
        self.openDemonstrationRoute = openDemonstrationRoute
        _library = StateObject(wrappedValue: HelpLibrary())
    }

    init(
        library: HelpLibrary,
        guideCoordinator: GuidedHelpPresentationCoordinator? = nil,
        openDemonstrationRoute: @escaping @MainActor (MechanicianRoute) -> Void = {
            _ = ActiveWorkspace.shared.open($0)
        }
    ) {
        self.guideCoordinator = guideCoordinator
        self.openDemonstrationRoute = openDemonstrationRoute
        _library = StateObject(wrappedValue: library)
    }

    private var resetRevision: UInt64? {
        let activation = bridge.inspectorTabUserActivation
        guard HelpInspectorTabActivationPolicy.shouldReturnToCatalog(
            activation: activation
        ), let activation else { return nil }
        return activation.revision
    }

    var body: some View {
        let admittedCoordinator = admittedGuideCoordinator
        HelpBrowserView(
            library: library,
            host: .workspaceInspector,
            resetRevision: resetRevision,
            guideCoordinator: admittedCoordinator,
            openDemonstrationRoute: openDemonstrationRoute,
            openHelpWorkspaceAction: {})
    }

    private var admittedGuideCoordinator: GuidedHelpPresentationCoordinator? {
        guard HelpWorkspace.owns(bridge.projectID),
              let window = bridge.window,
              guideCoordinator?.owner.matches(bridge: bridge, window: window) == true else {
            return nil
        }
        return guideCoordinator
    }
}

/// Searchable, source-backed product Help shared by the standalone window and workspace inspector.
@MainActor
private struct HelpBrowserView: View {
    @ObservedObject var library: HelpLibrary
    let host: HelpBrowserHost
    let resetRevision: UInt64?
    let guideCoordinator: GuidedHelpPresentationCoordinator?
    let openDemonstrationRoute: @MainActor (MechanicianRoute) -> Void
    let openHelpWorkspaceAction: @MainActor () -> Void
    @State private var navigation = HelpReaderNavigationState()
    @State private var query = ""
    @State private var includeHistory = false
    @State private var layout: HelpBrowserLayout = .split
    @State private var pendingGuideArticleID: String?
    @State private var guideScrollTarget: HelpGuideArticleScrollTarget?
    @State private var guideReaderSession: HelpGuideReaderSession?

    init(
        library: HelpLibrary,
        host: HelpBrowserHost,
        resetRevision: UInt64? = nil,
        guideCoordinator: GuidedHelpPresentationCoordinator? = nil,
        openDemonstrationRoute: @escaping @MainActor (MechanicianRoute) -> Void,
        openHelpWorkspaceAction: @escaping @MainActor () -> Void
    ) {
        self.library = library
        self.host = host
        self.resetRevision = resetRevision
        self.guideCoordinator = guideCoordinator
        self.openDemonstrationRoute = openDemonstrationRoute
        self.openHelpWorkspaceAction = openHelpWorkspaceAction
    }

    private var selection: HelpSelection? {
        navigation.selection
    }

    private var selectionBinding: Binding<HelpSelection?> {
        Binding(
            get: { navigation.selection },
            set: { navigation.select($0) })
    }

    private var queryIsEmpty: Bool {
        query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var selectedArticleID: String? {
        switch selection {
        case .article(let id):
            return id
        case .searchResult(let id):
            return library.searchHit(id: id)?.article.id
        case .liveInventory, nil:
            return nil
        }
    }

    var body: some View {
        Group {
            switch host {
            case .standalone:
                standaloneSplitReader
            case .workspaceInspector:
                GeometryReader { geometry in
                    let container = helpBrowserContainer(
                        width: geometry.size.width,
                        host: host)
                    let resolved = helpBrowserLayout(
                        width: geometry.size.width,
                        host: host)
                    Group {
                        switch container {
                        case .boundedInspectorSplit:
                            boundedInspectorSplitReader(
                                HelpInspectorSplitLayout(
                                    width: geometry.size.width,
                                    sidebarWidths: host.sidebarWidths))
                        case .compactInspector:
                            compactReader
                        case .nativeNavigationSplit:
                            // The host policy above makes this unreachable. Keeping the fallback
                            // compact also fails closed if a future host case is added incorrectly.
                            compactReader
                        }
                    }
                    .onChange(of: resolved, initial: true) { _, value in
                        layout = value
                        guard value == .split else { return }
                        navigation.reconcileSearch(
                            searchNavigationOutcome(library.searchState),
                            queryIsEmpty: queryIsEmpty,
                            automaticallySelectFirstResult: true)
                    }
                }
            }
        }
        .background(Color.nBg)
        .onChange(of: library.state, initial: true) { _, state in
            switch state {
            case .loading:
                break
            case .ready:
                navigation.corpusBecameReady(
                    firstArticleID: library.firstArticleID,
                    queryIsEmpty: queryIsEmpty)
            case .unavailable:
                guideCoordinator?.exit()
                navigation.corpusBecameUnavailable()
            }
        }
        .onChange(of: navigation.selection) { _, value in
            guideReaderSession?.observe(selection: value)
            switch value {
            case let .article(id):
                library.loadArticle(id: id)
            case let .searchResult(id):
                guard let hit = library.searchHit(id: id) else {
                    library.clearArticleSelection()
                    return
                }
                library.loadArticle(id: hit.article.id, matched: hit)
            case .liveInventory:
                if host.showsLiveInventory {
                    library.clearArticleSelection()
                } else {
                    navigation.select(nil)
                }
            case nil:
                library.clearArticleSelection()
            }
        }
        .onChange(of: query) { oldValue, value in
            guideReaderSession?.observe(query: value, includeHistory: includeHistory)
            let nextIncludeHistory = helpHistorySelection(
                query: value,
                currentValue: includeHistory)
            if includeHistory != nextIncludeHistory {
                includeHistory = nextIncludeHistory
            }
            navigation.queryChanged(
                wasEmpty: oldValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                isEmpty: value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                firstArticleID: library.firstArticleID)
            if let articleID = pendingGuideArticleID {
                pendingGuideArticleID = nil
                navigation.select(.article(articleID))
            }
            library.search(text: value, includeHistory: nextIncludeHistory)
        }
        .onChange(of: includeHistory) { _, value in
            guideReaderSession?.observe(query: query, includeHistory: value)
            guard !queryIsEmpty else { return }
            navigation.searchRestarted()
            library.search(text: query, includeHistory: value)
        }
        .onChange(of: library.searchState) { _, state in
            navigation.reconcileSearch(
                searchNavigationOutcome(state),
                queryIsEmpty: queryIsEmpty,
                automaticallySelectFirstResult: layout == .split)
        }
        .onChange(of: resetRevision) { oldValue, value in
            guard value != nil, value != oldValue else { return }
            guideCoordinator?.exit()
            returnToCatalog()
        }
    }

    private var standaloneSplitReader: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(
                    min: host.sidebarWidths.minimum,
                    ideal: host.sidebarWidths.ideal,
                    max: host.sidebarWidths.maximum)
        } detail: {
            detail
        }
    }

    private func boundedInspectorSplitReader(
        _ columns: HelpInspectorSplitLayout
    ) -> some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: columns.sidebarWidth)
                .frame(maxHeight: .infinity)
            Divider()
                .frame(width: columns.dividerWidth)
                .frame(maxHeight: .infinity)
            detail
                .frame(width: columns.detailWidth)
                .frame(maxHeight: .infinity)
        }
        .frame(width: columns.containerWidth, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        // A nested reader must never paint into the inspector tab bar or conversation column,
        // even if one of its SwiftUI children later acquires a larger intrinsic content size.
        .clipped()
    }

    @ViewBuilder
    private var compactReader: some View {
        if selection == nil {
            sidebar
        } else {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Button {
                        navigation.select(nil)
                    } label: {
                        Label(
                            queryIsEmpty ? "Topics" : "Search results",
                            systemImage: "chevron.left")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("help.compact.back")
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                Divider()
                detail
            }
        }
    }

    private func returnToCatalog() {
        query = ""
        includeHistory = false
        navigation.returnToCatalog()
        library.clearArticleSelection()
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            searchField
            guidedHelpEntry
            if host.showsExpertHandoff {
                askMechanicianEntry
            }
            List(selection: selectionBinding) {
                switch library.state {
                case .loading:
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Loading Help…").font(.caption).foregroundStyle(.secondary)
                    }
                    .accessibilityIdentifier("help.sidebar.loading")
                case .unavailable:
                    Label("Help isn’t available in this build.", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(Color.nWarningText)
                        .accessibilityIdentifier("help.sidebar.unavailable")
                case .ready:
                    if queryIsEmpty {
                        catalogSections
                    } else {
                        searchResults
                    }
                }
                if host.showsLiveInventory {
                    Section("This conversation") {
                        sidebarRow(
                            selection: .liveInventory,
                            icon: "wand.and.stars",
                            title: "What it can do",
                            blurb: "Live inventory of tools, skills and automations")
                        .accessibilityIdentifier("help.liveInventory")
                    }
                }
            }
            .listStyle(.sidebar)
            .guidedHelpTarget(.helpTopics, registry: guideCoordinator?.registry)
        }
    }

    private var askMechanicianEntry: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Need an answer beyond this topic?")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button(action: openHelpWorkspaceAction) {
                Label("Ask Mechanician", systemImage: HelpWorkspace.iconSymbol)
            }
            .buttonStyle(PillButtonStyle(kind: .accent))
            .accessibilityHint("Open or focus the Help workspace")
            .accessibilityIdentifier("help.askMechanician")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private var guidedHelpEntry: some View {
        let available = library.guides.filter {
            helpGuideIsAvailable(
                $0,
                host: host,
                hasExactCoordinator: guideCoordinator != nil)
        }
        if queryIsEmpty, !includeHistory, !available.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(available) { guide in
                    Button {
                        startGuide(guide)
                    } label: {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "sparkles.rectangle.stack")
                                .foregroundStyle(Color.nInfoText)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Start tour")
                                    .font(.system(size: 9.5, weight: .semibold))
                                    .foregroundStyle(Color.nInfoText)
                                Text(verbatim: guide.title)
                                    .font(.caption.weight(.semibold))
                                Text(verbatim: guide.summary)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .padding(10)
                    .cardSurface(cornerRadius: 9)
                    .accessibilityLabel(Text("Start tour: \(guide.title)"))
                    .accessibilityHint("Start a native guided tour in this window")
                    .accessibilityIdentifier("help.guide.\(guide.id)")
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 9)
            .accessibilityIdentifier("help.guides")
        }
    }

    private func startGuide(_ signedGuide: MechanicianHelpGuide) {
        guard library.state == .ready,
              queryIsEmpty,
              !includeHistory,
              signedGuide.lifecycle == .current,
              library.articleSummary(id: signedGuide.articleID) != nil,
              let metadata = library.metadata,
              let coordinator = guideCoordinator,
              let presentation = GuidedHelpPresentationGuide(
                signedGuide: signedGuide,
                corpusDigest: metadata.contentSHA256)
        else { return }

        coordinator.exit()
        let navigation = $navigation
        let query = $query
        let includeHistory = $includeHistory
        let pendingGuideArticleID = $pendingGuideArticleID
        let guideScrollTarget = $guideScrollTarget
        let guideReaderSession = $guideReaderSession
        let expectedCorpusDigest = presentation.corpusDigest
        let articleID = presentation.articleID
        let readerSession = HelpGuideReaderSession(navigation: navigation.wrappedValue)
        guideReaderSession.wrappedValue = readerSession
        let hooks = GuidedHelpPresentationHooks(
            prepareStep: { [weak coordinator, weak library, weak readerSession] step, temporaryState in
                guard let readerSession else { coordinator?.exit(); return }
                _ = temporaryState.restoreOnEnd(key: .init("help-reader-navigation")) {
                    guard guideReaderSession.wrappedValue === readerSession else { return }
                    if readerSession.canRestore {
                        navigation.wrappedValue = readerSession.initialNavigation
                        guideScrollTarget.wrappedValue = nil
                    }
                    pendingGuideArticleID.wrappedValue = nil
                    guideReaderSession.wrappedValue = nil
                }
                guard let library,
                      library.state == .ready,
                      library.metadata?.contentSHA256 == expectedCorpusDigest else {
                    coordinator?.exit()
                    return
                }
                switch helpGuideRevealDestination(for: step.revealAction) {
                case .unchanged:
                    break
                case .topics:
                    readerSession.expect(selection: nil)
                    query.wrappedValue = ""
                    includeHistory.wrappedValue = false
                    guideScrollTarget.wrappedValue = nil
                    navigation.wrappedValue.returnToCatalog()
                    library.clearArticleSelection()
                case .article(let target):
                    readerSession.expect(selection: .article(articleID))
                    let clearsSearch = !query.wrappedValue
                        .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    pendingGuideArticleID.wrappedValue = clearsSearch ? articleID : nil
                    query.wrappedValue = ""
                    includeHistory.wrappedValue = false
                    navigation.wrappedValue.select(.article(articleID))
                    guideScrollTarget.wrappedValue = target
                    library.loadArticle(id: articleID)
                }
            },
            didFinish: { _ in
                pendingGuideArticleID.wrappedValue = nil
                guideScrollTarget.wrappedValue = nil
            })
        if coordinator.present(presentation, hooks: hooks) != .started {
            guideReaderSession.wrappedValue = nil
        }
    }

    private var searchField: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Search Help", text: $query)
                    .textFieldStyle(.plain)
                    .accessibilityIdentifier("help.search")
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Clear the Help search")
                    .accessibilityLabel("Clear the Help search")
                    .accessibilityIdentifier("help.clearSearch")
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .cardSurface(cornerRadius: 8)
            .guidedHelpTarget(.helpSearchField, registry: guideCoordinator?.registry)

            if !queryIsEmpty {
                Button {
                    includeHistory.toggle()
                } label: {
                    Label(
                        "Include history",
                        systemImage: includeHistory
                            ? "checkmark.circle.fill"
                            : "clock.arrow.circlepath")
                }
                .buttonStyle(PillButtonStyle(kind: includeHistory ? .accent : .neutral))
                .accessibilityAddTraits(includeHistory ? .isSelected : [])
                .accessibilityValue(includeHistory ? "On" : "Off")
                .accessibilityIdentifier("help.includeHistory")
                .help("Include historical, superseded, and retired claims")
                .fixedSize()
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 9)
    }

    @ViewBuilder
    private var catalogSections: some View {
        ForEach(library.sections) { section in
            Section {
                ForEach(section.articles) { article in
                    sidebarRow(
                        selection: .article(article.id),
                        icon: article.icon,
                        title: article.title,
                        blurb: article.blurb)
                    .accessibilityIdentifier("help.catalog.article.\(article.id)")
                }
            } header: {
                Text(verbatim: section.title)
            }
        }
    }

    @ViewBuilder
    private var searchResults: some View {
        Section("Search Results") {
            switch library.searchState {
            case .idle, .searching:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Searching…").font(.caption).foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("help.search.searching")
            case .empty:
                VStack(alignment: .leading, spacing: 3) {
                    Text("No matching Help").font(.caption).fontWeight(.medium)
                    Text("Try a feature name, setting, command, or symptom.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
                .accessibilityIdentifier("help.search.empty")
            case .failed:
                VStack(alignment: .leading, spacing: 3) {
                    Label("Search unavailable", systemImage: "exclamationmark.triangle")
                        .font(.caption).fontWeight(.medium)
                        .foregroundStyle(Color.nWarningText)
                    Text("Change the search to try again.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
                .accessibilityIdentifier("help.search.failed")
            case .results:
                ForEach(library.searchHits) { hit in
                    searchRow(hit)
                        .accessibilityIdentifier("help.result.\(hit.id)")
                }
            }
        }
    }

    private func sidebarRow(
        selection rowSelection: HelpSelection,
        icon: String,
        title: String,
        blurb: String
    ) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: title).font(.system(size: 13, weight: .medium))
                Text(verbatim: blurb).font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
        } icon: {
            sidebarIcon(systemName: icon, isSelected: selection == rowSelection)
        }
        .padding(.vertical, 3)
        .tag(rowSelection)
        .accessibilityLabel(Text(verbatim: title))
        .accessibilityHint(Text(verbatim: blurb))
    }

    private func searchRow(_ hit: MechanicianHelpSearchHit) -> some View {
        let rowSelection = HelpSelection.searchResult(hit.id)
        let lifecycle = helpLifecycleLabel(hit.claim.lifecycle)
        let excerpt = HelpLibrary.excerpt(hit.claim.body, matching: query, limit: 105)
        return HStack(alignment: .top, spacing: 8) {
            sidebarIcon(systemName: hit.article.icon, isSelected: selection == rowSelection)
                .frame(width: 17)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(verbatim: hit.article.title)
                        .font(.system(size: 12.5, weight: .medium))
                        .lineLimit(1)
                        .accessibilityIdentifier("help.result.\(hit.id).article")
                    if hit.claim.lifecycle != .current {
                        Text(verbatim: lifecycle)
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(Color.nWarningText)
                            .accessibilityLabel(Text(verbatim: "Lifecycle: \(lifecycle)"))
                            .accessibilityIdentifier("help.result.\(hit.id).lifecycle")
                    }
                }
                if hit.claim.heading != hit.article.title {
                    Text(verbatim: hit.claim.heading)
                        .font(.caption2).foregroundStyle(Color.nInfoText).lineLimit(1)
                        .accessibilityIdentifier("help.result.\(hit.id).heading")
                }
                Text(verbatim: excerpt)
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                    .accessibilityLabel(Text(verbatim: "Excerpt: \(excerpt)"))
                    .accessibilityIdentifier("help.result.\(hit.id).excerpt")
            }
        }
        .padding(.vertical, 3)
        .tag(rowSelection)
        .accessibilityElement(children: .contain)
        .accessibilityValue(Text(verbatim: "Lifecycle: \(lifecycle)"))
        .accessibilityHint("Open this Help result")
    }

    @ViewBuilder
    private func sidebarIcon(systemName: String, isSelected: Bool) -> some View {
        switch helpSidebarIconForegroundPolicy(isSelected: isSelected) {
        case .inherited:
            Image(systemName: systemName)
        case .info:
            Image(systemName: systemName).foregroundStyle(Color.nInfoText)
        }
    }

    @ViewBuilder
    private var detail: some View {
        if host.showsLiveInventory, selection == .liveInventory {
            AgentAbilitiesView()
        } else {
            switch library.state {
            case .loading:
                ProgressView("Loading Help…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier("help.detail.loading")
            case .unavailable:
                unavailableDetail
            case .ready:
                readyDetail
            }
        }
    }

    @ViewBuilder
    private var readyDetail: some View {
        if selection == nil {
            noSelectionDetail
        } else if let selectedArticleID {
            switch library.articleState {
            case .idle, .loading:
                articleLoadingDetail
            case .ready(let loadedID):
                if loadedID == selectedArticleID,
                   let article = library.selectedArticle,
                   article.id == selectedArticleID {
                    articleDetail(article)
                } else {
                    articleLoadingDetail
                }
            case .failed(let failedID):
                if failedID == selectedArticleID {
                    articleFailureDetail
                } else {
                    articleLoadingDetail
                }
            }
        } else {
            noSelectionDetail
        }
    }

    private var articleLoadingDetail: some View {
        ProgressView("Opening topic…")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("help.article.loading")
    }

    @ViewBuilder
    private var noSelectionDetail: some View {
        if queryIsEmpty {
            Text("Choose a topic.").font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("help.detail.chooseTopic")
        } else {
            switch library.searchState {
            case .idle, .searching, .results:
                ProgressView("Searching Help…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier("help.detail.searching")
            case .empty:
                readerMessage(
                    icon: "magnifyingglass",
                    title: Text("No matching Help"),
                    detail: Text("Try a feature name, setting, command, or symptom."),
                    identifier: "help.detail.noResults")
            case .failed:
                readerMessage(
                    icon: "exclamationmark.triangle",
                    title: Text("Search unavailable"),
                    detail: Text("The Help corpus couldn’t complete this search. Change the search to try again."),
                    identifier: "help.detail.searchFailed")
            }
        }
    }

    private var unavailableDetail: some View {
        VStack(spacing: 10) {
            Image(systemName: "book.closed")
                .font(.system(size: 28)).foregroundStyle(Color.nWarningText)
            Text("Help isn’t available in this build.")
                .font(.headline)
            Text("The signed product-knowledge resource is missing or does not match this app build.")
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("help.detail.unavailable")
    }

    private var articleFailureDetail: some View {
        readerMessage(
            icon: "doc.badge.exclamationmark",
            title: Text("Topic unavailable"),
            detail: Text("This Help topic couldn’t be read from the signed product-knowledge resource."),
            identifier: "help.article.failed")
    }

    private func readerMessage(
        icon: String,
        title: Text,
        detail: Text,
        identifier: String
    ) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 28))
                .foregroundStyle(Color.nWarningText)
            title.font(.headline)
            detail
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier(identifier)
    }

    private func articleDetail(_ article: MechanicianHelpArticle) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 18) {
                        buildIdentityRow(article)
                        if case let .searchResult(resultID) = selection,
                           let match = library.selectedMatch,
                           match.id == resultID,
                           match.article.id == article.id {
                            matchedAnswer(match)
                        }
                        MarkdownText(text: article.markdown)
                            .textSelection(.enabled)
                    }
                    .id(HelpGuideArticleScrollTarget.content.rawValue)
                    .guidedHelpTarget(
                        .helpArticleContent,
                        registry: guideCoordinator?.registry)

                    demonstrationSection(article.demonstrations)
                        .id(HelpGuideArticleScrollTarget.demonstrations.rawValue)
                        .guidedHelpTarget(
                            .helpDemonstrations,
                            registry: guideCoordinator?.registry)

                    evidenceSection(article.evidence)
                        .id(HelpGuideArticleScrollTarget.evidence.rawValue)
                        .guidedHelpTarget(
                            .helpArticleEvidence,
                            registry: guideCoordinator?.registry)
                }
                .padding(24)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onAppear { scrollToGuideTarget(using: proxy) }
            .onChange(of: guideScrollTarget) { _, _ in
                scrollToGuideTarget(using: proxy)
            }
        }
    }

    private func scrollToGuideTarget(using proxy: ScrollViewProxy) {
        guard let target = guideScrollTarget,
              let readerSession = guideReaderSession else { return }
        // This is the Help article's own scroll view, not the conversation transcript. The
        // transcript remains exclusively owned by TranscriptPinController.
        DispatchQueue.main.async {
            guard guideScrollTarget == target,
                  guideReaderSession === readerSession,
                  guideCoordinator?.snapshot?.corpusDigest
                    == library.metadata?.contentSHA256 else { return }
            proxy.scrollTo(target.rawValue, anchor: .top)
            guideCoordinator?.refreshLayout()
        }
    }

    @ViewBuilder
    private func demonstrationSection(
        _ demonstrations: [MechanicianHelpDemonstration]
    ) -> some View {
        let available = demonstrations.filter {
            helpDemonstrationIsAvailable(
                $0,
                allowsProductActions: host.allowsDemonstrations)
        }
        if !available.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Divider()
                Text(String(localized: "Try a workflow"))
                    .font(.headline)
                Text(String(localized: "Open a reviewed demonstration request in a new conversation. You can inspect or edit it before sending."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(available) { demonstration in
                    HStack(alignment: .top, spacing: 14) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(verbatim: demonstration.title)
                                .font(.subheadline.weight(.semibold))
                            Text(verbatim: demonstration.outcome)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 10)
                        Button {
                            guard let route = helpDemonstrationDraftRoute(
                                for: demonstration,
                                allowsProductActions: host.allowsDemonstrations)
                            else { return }
                            openDemonstrationRoute(route)
                        } label: {
                            Label(String(localized: "Try workflow"), systemImage: "play.fill")
                        }
                        .buttonStyle(PillButtonStyle(kind: .accent))
                        .fixedSize()
                        .accessibilityLabel(
                            Text(verbatim: helpDemonstrationPromptField(
                                String(localized: "Try workflow:"),
                                value: demonstration.title)))
                        .accessibilityHint(
                            String(localized: "Open an unsent demonstration request in a new conversation"))
                        .accessibilityIdentifier("help.demonstration.\(demonstration.id)")
                    }
                    .padding(12)
                    .cardSurface(cornerRadius: 10)
                }
            }
            .accessibilityIdentifier("help.demonstrations")
        }
    }

    private func buildIdentityRow(_ article: MechanicianHelpArticle) -> some View {
        let lifecycle = helpLifecycleLabel(article.summary.lifecycle)
        return HStack(spacing: 7) {
            Label("Included with this build", systemImage: "checkmark.seal.fill")
                .font(.caption).foregroundStyle(Color.nSuccessText)
                .accessibilityIdentifier("help.article.buildInclusion")
            if let metadata = library.metadata {
                Text(verbatim: "\(metadata.applicationVersion) (\(metadata.applicationBuild))")
                    .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                    .accessibilityLabel(Text(verbatim: "Build \(metadata.applicationVersion), \(metadata.applicationBuild)"))
                    .accessibilityIdentifier("help.article.buildVersion")
            }
            Spacer(minLength: 0)
            Text(verbatim: "\(article.summary.kind.displayName) · \(lifecycle)")
                .font(.caption2).foregroundStyle(.secondary)
                .accessibilityLabel(Text(verbatim: "\(article.summary.kind.displayName), lifecycle: \(lifecycle)"))
                .accessibilityIdentifier("help.article.lifecycle")
        }
    }

    private func matchedAnswer(_ hit: MechanicianHelpSearchHit) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "sparkle.magnifyingglass").foregroundStyle(Color.nInfoText)
                matchTitle(hit.claim.lifecycle).font(.caption).fontWeight(.semibold)
                if hit.claim.lifecycle != .current {
                    let lifecycle = helpLifecycleLabel(hit.claim.lifecycle)
                    Text(verbatim: lifecycle)
                        .font(.caption2).foregroundStyle(Color.nWarningText)
                        .accessibilityLabel(Text(verbatim: "Lifecycle: \(lifecycle)"))
                        .accessibilityIdentifier("help.match.lifecycle")
                }
            }
            Text(verbatim: hit.claim.heading)
                .font(.headline)
                .accessibilityIdentifier("help.match.heading")
            Text(verbatim: hit.claim.body)
                .font(.body).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("help.match.answer")
            evidenceRows(
                hit.evidence,
                compact: true,
                identifierPrefix: "help.match.evidence")
        }
        .padding(14)
        .cardSurface(cornerRadius: 10)
        .accessibilityIdentifier("help.match")
    }

    private func matchTitle(_ lifecycle: MechanicianHelpLifecycle) -> Text {
        switch lifecycle {
        case .current: Text("Matched answer")
        case .historical: Text("Historical match")
        case .superseded: Text("Superseded material")
        case .retired: Text("Retired material")
        }
    }

    private func evidenceSection(_ evidence: [MechanicianHelpEvidence]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            Text("Evidence").font(.headline)
            Text("These tracked anchors support the product claims in this article.")
                .font(.caption).foregroundStyle(.secondary)
            evidenceRows(
                evidence,
                compact: false,
                identifierPrefix: "help.article.evidence")
        }
    }

    private func evidenceRows(
        _ evidence: [MechanicianHelpEvidence],
        compact: Bool,
        identifierPrefix: String
    ) -> some View {
        VStack(alignment: .leading, spacing: compact ? 6 : 9) {
            ForEach(evidence) { item in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: item.kind.icon)
                        .foregroundStyle(Color.nInfoText).frame(width: 16)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(verbatim: helpEvidenceKindLabel(item.kind))
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(verbatim: item.path)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(Color.nInfoText)
                        }
                        Text(verbatim: item.anchor)
                            .font(.caption2).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: "\(helpEvidenceKindLabel(item.kind)) evidence: \(item.path)"))
                .accessibilityValue(Text(verbatim: item.anchor))
                .accessibilityHint("Evidence anchor")
                .accessibilityIdentifier("\(identifierPrefix).\(item.id)")
            }
        }
    }

    private func searchNavigationOutcome(
        _ state: HelpLibrary.SearchState
    ) -> HelpSearchNavigationOutcome {
        switch state {
        case .idle, .searching:
            return .searching
        case .results:
            return .results(library.searchHits.map(\.id))
        case .empty:
            return .empty
        case .failed:
            return .failed
        }
    }
}

private extension MechanicianHelpClaimKind {
    var displayName: String {
        switch self {
        case .howTo: "How-to"
        case .architecture: "Architecture"
        case .extensionPoint: "Extension point"
        case .troubleshooting: "Troubleshooting"
        case .history: "History"
        }
    }
}

private extension MechanicianHelpEvidenceKind {
    var icon: String {
        switch self {
        case .source: "chevron.left.forwardslash.chevron.right"
        case .test: "checkmark.diamond"
        case .architecture: "square.3.layers.3d"
        case .canonicalDoc: "doc.text"
        case .release: "shippingbox"
        case .history: "clock.arrow.circlepath"
        }
    }
}
