import SwiftUI
import AppKit
import Darwin

/// The honest relationship between one conversation's file history and the workspace's current Git
/// state. `committed` is used only when the daemon proved that Git history contains the exact bytes
/// recorded after the successful edit; a clean worktree by itself is never commit evidence.
enum ConversationFileOutcome: Equatable {
    case uncommitted(String)
    case committed(String)
    case readOnly
    case noCurrentDiff
    case outsideRepository
    case notVersionControlled
    case gitUnavailable

    var label: String {
        switch self {
        case .uncommitted(let state): return "Uncommitted · \(state)"
        case .committed(let commit): return "Committed in \(commit)"
        case .readOnly: return "Read only"
        case .noCurrentDiff: return "No current diff: committed or reverted"
        case .outsideRepository: return "Outside this Git repository"
        case .notVersionControlled: return "Not under version control"
        case .gitUnavailable: return "Git status unavailable"
        }
    }

    /// Conversation History is not a second porcelain-status list, but repository rows still need
    /// the same leading status geometry. A checkmark is reserved for exact Git-history proof; a
    /// question mark makes an edited, currently clean file visibly unresolved instead of implying
    /// that it was committed. Other outcomes intentionally leave the marker column empty.
    var gitStatusMarker: ConversationHistoryGitStatusMarker? {
        switch self {
        case .committed(let commit):
            return ConversationHistoryGitStatusMarker(
                glyph: "✓",
                accessibilityLabel: "Already committed in \(commit)")
        case .noCurrentDiff:
            return ConversationHistoryGitStatusMarker(
                glyph: "?",
                accessibilityLabel: "No current Git change; commit or revert not determined")
        default:
            return nil
        }
    }
}

struct ConversationHistoryGitStatusMarker: Equatable {
    let glyph: String
    let accessibilityLabel: String
}

func conversationFileOutcome(
    for activity: AgentBridge.TouchedFile,
    git: GitStatus,
    workspaceCwd: String
) -> ConversationFileOutcome {
    guard git.belongs(to: workspaceCwd) else { return .gitUnavailable }
    guard git.isRepo else {
        return git.probe == .notRepository ? .notVersionControlled : .gitUnavailable
    }
    if let file = matchingGitFile(forAbsolute: activity.path, in: git) {
        let state: String
        if file.untracked {
            state = "Untracked"
        } else if file.hasStagedChange && file.hasUnstagedChange {
            state = "Staged + \(file.statusName(stagedSide: false).lowercased())"
        } else if file.hasStagedChange {
            state = "Staged"
        } else {
            state = file.statusName(stagedSide: false)
        }
        return .uncommitted(state)
    }

    let root = (git.repoRoot as NSString).standardizingPath
    let candidate = (activity.path as NSString).standardizingPath
    guard candidate == root || candidate.hasPrefix(root + "/") else { return .outsideRepository }
    if let commit = git.activityCommits[candidate],
       let observedDigest = activity.postEditDigest,
       let committedDigest = git.activityCommitDigests[candidate],
       observedDigest == committedDigest {
        return .committed(commit)
    }
    return activity.edits == 0 ? .readOnly : .noCurrentDiff
}

/// Disclosure defaults differ by role, but both kinds of Conversation remain user-controlled.
/// Keeping the policy outside SwiftUI makes the chevron's state and action independently testable.
struct ChangesConversationDisclosureState: Equatable {
    private var expandedOtherConversationIDs = Set<UUID>()
    private var collapsedCurrentConversationIDs = Set<UUID>()

    func isExpanded(conversationID: UUID, isCurrent: Bool) -> Bool {
        isCurrent
            ? !collapsedCurrentConversationIDs.contains(conversationID)
            : expandedOtherConversationIDs.contains(conversationID)
    }

    mutating func toggle(conversationID: UUID, isCurrent: Bool) {
        if isCurrent {
            if collapsedCurrentConversationIDs.contains(conversationID) {
                collapsedCurrentConversationIDs.remove(conversationID)
            } else {
                collapsedCurrentConversationIDs.insert(conversationID)
            }
        } else if expandedOtherConversationIDs.contains(conversationID) {
            expandedOtherConversationIDs.remove(conversationID)
        } else {
            expandedOtherConversationIDs.insert(conversationID)
        }
    }
}

/// A Conversation-first integration view inside the existing Changes inspector. Intent and agent
/// reports stay visibly separate from mechanically observed work; the traditional staged/unstaged
/// Git list remains last and authoritative only for the current checkout. Expanding another
/// Conversation never navigates the transcript, and every file selection uses one shared preview.
struct ChangesPanelView: View {
    /// A visible Changes panel should converge on repository truth even when an external shell or
    /// long-running release command changes Git without producing a Mechanician lifecycle event.
    /// SwiftUI cancels this task as soon as the tab or inspector disappears, so closed panels do
    /// not poll. AgentBridge skips a tick while an earlier status request is still in flight.
    private static let autoRefreshNanoseconds: UInt64 = 2_000_000_000

    @EnvironmentObject private var bridge: AgentBridge
    @Environment(\.uiScale) private var uiScale
    @ObservedObject private var capabilityStore = ProviderCapabilityStore.shared
    @ObservedObject private var activeWorkspace = ActiveWorkspace.shared
    /// Immutable authority input. The default keeps every existing call site source-compatible;
    /// AgentBridge/ConversationStore can feed durable records without making this view query SQLite.
    private let authorityEvidence: ChangesInspectorEvidence
    private let evidenceLoadFailed: Bool
    private let onRequestContext: ((UUID) -> Void)?
    @State private var commitMessage = ""
    /// The ONE selected change (a session-touched file's absolute path). Its reconstructed diff shows
    /// in the shared pane; selecting a git file instead clears this and fills `bridge.gitDiff`. One
    /// selection, one diff view — no dual display.
    @State private var selectedTouchedPath: String?
    @State private var selectedObservedKey: String?
    @State private var selectedGitKey: String?
    @State private var conversationDisclosure = ChangesConversationDisclosureState()
    @AppStorage("changesPreviewHeight") private var previewHeight = 320.0

    init(
        evidence: ChangesInspectorEvidence = .empty,
        evidenceLoadFailed: Bool = false,
        onRequestContext: ((UUID) -> Void)? = nil
    ) {
        authorityEvidence = evidence
        self.evidenceLoadFailed = evidenceLoadFailed
        self.onRequestContext = onRequestContext
    }

    private var touched: [AgentBridge.TouchedFile] {
        bridge.currentID.flatMap { bridge.touchedFiles[$0] } ?? []
    }

    private var liveObservedFiles: [UUID: [ChangesObservedFileEvidence]] {
        bridge.touchedFiles.reduce(into: [:]) { result, pair in
            let (conversationID, files) = pair
            result[conversationID] = files.map { file in
                let state: ChangesFileRepositoryState?
                if bridge.currentID == conversationID {
                    state = repositoryState(for: conversationFileOutcome(
                        for: file, git: bridge.git, workspaceCwd: bridge.cwd))
                } else {
                    state = nil
                }
                return ChangesObservedFileEvidence(
                    id: "session:\(file.path)",
                    path: file.path,
                    operation: file.edits > 0 ? .edited : .read,
                    provenance: .directFileTool(toolUseID: nil),
                    capturedAt: file.lastAt,
                    afterDigest: file.postEditDigest,
                    patch: file.diff.isEmpty ? nil : file.diff,
                    repositoryState: state)
            }
        }
    }

    private var presentation: ChangesInspectorPresentation {
        ChangesInspectorPresentation.make(
            currentConversationID: bridge.currentID,
            summaries: bridge.conversationSummaries,
            evidence: authorityEvidence,
            liveObservedFiles: liveObservedFiles)
    }
    private var hasAnyObservedFiles: Bool {
        renderedConversations.contains { !$0.work.flatMap(\.observedFiles).isEmpty }
    }

    private var hasCurrentGitSnapshot: Bool { bridge.git.belongs(to: bridge.cwd) }
    private var isCurrentRepo: Bool { hasCurrentGitSnapshot && bridge.git.isRepo }

    private func activity(for file: GitFile) -> AgentBridge.TouchedFile? {
        touched.first { activity in
            file.operationPaths.contains { bridge.git.absolutePath($0) == activity.path }
        }
    }

    private func shouldShowActivityBadge(for file: GitFile, staged: Bool) -> Bool {
        // A path can have both staged and unstaged changes. Put the conversation badge on the
        // worktree row when one exists, otherwise on its staged row, so it still appears once.
        staged ? !file.hasUnstagedChange : true
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if isCurrentRepo {
                InspectorPreviewSplit(previewHeight: $previewHeight) {
                    VStack(spacing: 0) {
                        sections.frame(minHeight: 140)
                        if !bridge.git.stagedFiles.isEmpty {
                            Divider()
                            commitBar
                        }
                    }
                } preview: {
                    diffPane
                }
            } else if bridge.git.probe == .unavailable, let issue = bridge.devToolIssue {
                // Developer tools are unavailable, but the separate activity log remains honest.
                sections.frame(maxHeight: 220)
                Divider()
                devToolBanner(issue)
            } else if hasAnyObservedFiles {
                // A non-git folder with edits: the SAME list + one diff pane as a repo (unified).
                InspectorPreviewSplit(previewHeight: $previewHeight) {
                    sections
                } preview: {
                    diffPane
                }
            } else {
                sections
            }
        }
        .onAppear { bridge.prepareProviderCapabilities() }
        .onChange(of: bridge.currentProviderCapabilityKey()) { _, _ in
            bridge.prepareProviderCapabilities()
        }
        .task(id: bridge.cwd) {
            guard !bridge.cwd.isEmpty else { return }
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: Self.autoRefreshNanoseconds)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                bridge.refreshGit(silently: true)
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            if isCurrentRepo {
                Image(systemName: "arrow.triangle.branch").scaledFont(11).foregroundStyle(.secondary)
                Text(bridge.git.branch.isEmpty ? "—" : bridge.git.branch)
                    .scaledFont(11, weight: .semibold).lineLimit(1)
                if bridge.git.ahead > 0 { Label("\(bridge.git.ahead)", systemImage: "arrow.up").scaledFont(10) }
                if bridge.git.behind > 0 { Label("\(bridge.git.behind)", systemImage: "arrow.down").scaledFont(10) }
            } else {
                Text("Changes").scaledFont(11, weight: .semibold)
            }
            Spacer()
            if isCurrentRepo {
                Button { bridge.gitPush() } label: { Image(systemName: "arrow.up.circle") }
                    .buttonStyle(.borderless).help("Push")
                    .disabled(bridge.git.ahead == 0 || bridge.devToolIssue != nil)
                    .accessibilityLabel("Push")
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
    }

    // MARK: - Sections

    @ViewBuilder private var sections: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                if evidenceLoadFailed {
                    Label(
                        "Conversation evidence is unavailable. Existing rows may be stale; Mechanician will retry on refresh.",
                        systemImage: "exclamationmark.triangle")
                        .scaledFont(10)
                        .foregroundStyle(Color.nWarningText)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(8)
                        .cardSurface(cornerRadius: 8)
                }
                conversationSections
                Divider().padding(.vertical, 2)
                repositoryChangesSection
            }
            .padding(8)
        }
    }

    @ViewBuilder private var conversationSections: some View {
        conversationSectionHeading(
            title: "Current Conversation",
            subtitle: "The Conversation you are working in stays first.",
            count: presentation.current == nil ? 0 : 1)
        if let current = presentation.current {
            conversationCard(
                current,
                expanded: conversationDisclosure.isExpanded(
                    conversationID: current.id,
                    isCurrent: true))
        } else {
            Text("No current Conversation is selected.")
                .scaledFont(10).foregroundStyle(.tertiary)
                .padding(.horizontal, 6).padding(.bottom, 4)
        }

        if !presentation.others.isEmpty {
            conversationSectionHeading(
                title: "Other Conversations",
                subtitle: "Exact repository-linked Conversations; opening one does not navigate away.",
                count: presentation.others.count)
                .padding(.top, 4)
            ForEach(presentation.others) { conversation in
                conversationCard(
                    conversation,
                    expanded: conversationDisclosure.isExpanded(
                        conversationID: conversation.id,
                        isCurrent: false))
            }
        }
    }

    private func conversationSectionHeading(title: String, subtitle: String, count: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                sectionHeader(title)
                Text(subtitle)
                    .scaledFont(9).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
            Text(verbatim: "\(count)")
                .scaledFont(10).foregroundStyle(.tertiary).monospacedDigit()
        }
    }

    @ViewBuilder private var repositoryChangesSection: some View {
        gitSectionHeader
        if isCurrentRepo {
            if let issue = bridge.devToolIssue {
                gitWriteToolBanner(issue)
            }
            if !bridge.git.stagedFiles.isEmpty {
                gitSection("Staged", bridge.git.stagedFiles, staged: true)
            }
            if !bridge.git.unstagedFiles.isEmpty {
                gitSection("Unstaged", bridge.git.unstagedFiles, staged: false)
            }
            if bridge.git.files.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("No uncommitted Git changes.")
                        .scaledFont(11, weight: .medium).foregroundStyle(.secondary)
                    Text("A clean worktree does not prove that Conversation work reached the target branch.")
                        .scaledFont(10).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 6).padding(.bottom, 4)
            }
        } else {
            gitWorkspaceState
        }
    }

    private var gitSectionHeader: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                sectionHeader("Repository Changes")
                Text("Traditional Git state for the current checkout; staged and unstaged remain separate.")
                    .scaledFont(9).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Text("\(bridge.git.files.count)")
                .scaledFont(10).foregroundStyle(.tertiary).monospacedDigit()
            if bridge.currentProviderSupportsNativeReview {
                Button { bridge.startCodexReviewCurrentChanges() } label: {
                    ViewThatFits(in: .horizontal) {
                        Label(
                            bridge.currentReviewIsRunning ? "Reviewing…" : "Review",
                            systemImage: "checkmark.bubble")
                        Image(systemName: "checkmark.bubble")
                    }
                }
                .buttonStyle(PillButtonStyle(kind: .neutral))
                .controlSize(.small)
                .disabled(!bridge.canStartCodexReviewCurrentChanges)
                .help(reviewHelp)
                .accessibilityLabel("Review uncommitted changes with Codex")
                .accessibilityValue(bridge.currentReviewIsRunning ? "Running" : "Ready")
            }
            Button { bridge.refreshGit() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless).help("Refresh Git status")
                .accessibilityLabel("Refresh Git status")
        }
    }

    private var reviewHelp: String {
        if bridge.currentReviewIsRunning { return "Codex is reviewing the current uncommitted changes." }
        if bridge.currentConversationHasReservedTurn {
            return "Finish or stop the current turn before starting a code review."
        }
        if bridge.git.files.isEmpty { return "There are no uncommitted Git changes to review." }
        return "Review the current uncommitted changes with Codex."
    }

    private func conversationCard(
        _ conversation: ChangesConversationPresentation,
        expanded: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                conversationDisclosure.toggle(
                    conversationID: conversation.id,
                    isCurrent: conversation.isCurrent)
            } label: {
                conversationHeader(conversation, expanded: expanded)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(verbatim: conversation.title))
            .accessibilityValue(Text(verbatim: conversationAccessibilityValue(
                conversation, expanded: expanded)))
            .accessibilityHint("Shows or hides this Conversation's request, report, and observed files without navigating")

            if expanded {
                Divider().padding(.leading, 26)
                VStack(alignment: .leading, spacing: 9) {
                    if conversation.work.isEmpty {
                        if let repository = conversation.repository {
                            repositoryEvidence(
                                repository,
                                hasUnprovedMutationWork: false)
                        } else {
                            Label("Repository checkout was not captured for this Conversation.",
                                  systemImage: "questionmark.circle")
                                .scaledFont(9).foregroundStyle(.tertiary)
                        }
                        noCapturedWork
                    } else {
                        ForEach(Array(conversation.work.enumerated()), id: \.element.id) { index, work in
                            if index > 0 { Divider().padding(.vertical, 2) }
                            workEvidence(
                                work,
                                conversationID: conversation.id,
                                fallbackRepository: conversation.repository,
                                showRecordHeading: conversation.work.count > 1)
                        }
                    }

                    if !conversation.isCurrent, let onRequestContext {
                        HStack {
                            Spacer()
                            let isQueued = bridge.pendingConversationWorkContextIDs.contains(
                                conversation.id)
                            Button {
                                onRequestContext(conversation.id)
                            } label: {
                                Label(
                                    isQueued ? "Remove from next agent turn" : "Attach to next agent turn",
                                    systemImage: isQueued
                                        ? "minus.circle" : "arrow.turn.down.right")
                            }
                            .buttonStyle(PillButtonStyle(kind: .neutral))
                            .controlSize(.small)
                            .help(isQueued
                                ? "Remove this frozen Conversation snapshot from the next current-agent turn."
                                : "Attach the visible request, agent report, repository source, and file evidence to the next current-agent turn.")
                        }
                    }
                }
                .padding(9)
            }
            Divider()
        }
        .background(Color.nBg)
    }

    private func conversationHeader(
        _ conversation: ChangesConversationPresentation,
        expanded: Bool
    ) -> some View {
        HStack(alignment: .center, spacing: 7) {
            Image(systemName: expanded ? "chevron.down" : "chevron.right")
                .scaledFont(9, weight: .semibold)
                .foregroundStyle(.secondary)
                .frame(width: 10)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(verbatim: conversation.title)
                        .scaledFont(12, weight: .semibold)
                        .lineLimit(1).truncationMode(.tail)
                    if conversation.isCurrent {
                        Text("CURRENT")
                            .scaledFont(8, weight: .bold)
                            .foregroundStyle(Color.nInfoText)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(Color.nAccent.opacity(0.14)))
                    }
                }
                conversationSummaryLine(conversation)
            }
            Spacer(minLength: 6)
            if activeWorkspace.runningConversations.contains(conversation.id)
                || conversation.summary.hasRunningDelegate {
                ProgressView()
                    .controlSize(.small)
                    .help("Agent still working")
                    .accessibilityHidden(true)
            } else if conversation.summary.awaitingQuestion {
                Image(systemName: "questionmark.bubble.fill")
                    .foregroundStyle(Color.nWarningText)
                    .help("Agent needs your answer")
                    .accessibilityHidden(true)
            } else if conversation.summary.errored {
                Image(systemName: "xmark.octagon.fill")
                    .foregroundStyle(Color.nErrorText)
                    .help("The last turn failed")
                    .accessibilityHidden(true)
            } else if conversation.summary.armedWaitSummary != nil {
                Image(systemName: "hourglass")
                    .foregroundStyle(Color.nWarningText)
                    .help("Conversation is waiting")
                    .accessibilityHidden(true)
            } else if let repository = conversation.repository {
                repositoryStateGlyph(
                    repository,
                    hasUnprovedMutationWork: conversationHasUnprovedMutation(conversation))
            }
        }
        .padding(.horizontal, 9).padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    private func conversationSummaryLine(_ conversation: ChangesConversationPresentation) -> some View {
        HStack(spacing: 5) {
            if conversation.work.isEmpty {
                Text("No captured work record")
            } else {
                Text(verbatim: "\(conversation.mutationFileCount) changed · \(conversation.observedFileCount) observed")
            }
            if let source = conversation.repository?.sourceLabel {
                Text("·")
                Text(verbatim: source).monospaced()
            }
        }
        .scaledFont(9)
        .foregroundStyle(.tertiary)
        .lineLimit(1)
    }

    @ViewBuilder private func repositoryStateGlyph(
        _ repository: ChangesRepositoryEvidence,
        hasUnprovedMutationWork: Bool
    ) -> some View {
        let detail = relationshipDetail(
            repository,
            hasUnprovedMutationWork: hasUnprovedMutationWork)
        if changesRepositoryCanShowIncludedCheck(
            repository,
            hasUnprovedMutationWork: hasUnprovedMutationWork) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Color.nSuccessText)
                .help(detail)
                .accessibilityHidden(true)
        } else if repository.relationship == .unknown {
            Image(systemName: "questionmark.circle")
                .foregroundStyle(.secondary)
                .help(detail)
                .accessibilityHidden(true)
        } else if repository.relationship.isIncluded {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.nWarningText)
                .help(detail)
                .accessibilityHidden(true)
        } else {
            Image(systemName: "arrow.triangle.branch")
                .foregroundStyle(Color.nWarningText)
                .help(detail)
                .accessibilityHidden(true)
        }
    }

    private func repositoryEvidence(
        _ repository: ChangesRepositoryEvidence,
        hasUnprovedMutationWork: Bool
    ) -> some View {
        let canShowIncludedCheck = changesRepositoryCanShowIncludedCheck(
            repository,
            hasUnprovedMutationWork: hasUnprovedMutationWork)
        return VStack(alignment: .leading, spacing: 5) {
            repositoryEvidenceLine(
                label: "SOURCE HEAD",
                value: repository.sourceLabel,
                detail: sourceDetail(repository),
                systemImage: "point.topleft.down.to.point.bottomright.curvepath")
            repositoryEvidenceLine(
                label: "CURRENT CHECKOUT",
                value: repository.currentCheckoutLabel ?? "Not available",
                detail: relationshipDetail(
                    repository,
                    hasUnprovedMutationWork: hasUnprovedMutationWork),
                systemImage: canShowIncludedCheck
                    ? "checkmark.circle.fill" : "scope")
            if repository.headReachability != .notChecked {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "arrow.triangle.branch")
                        .scaledFont(9).foregroundStyle(.secondary).frame(width: 11)
                    Text(verbatim: repository.headReachability.label)
                        .scaledFont(8).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 4) {
                Image(systemName: "clock")
                Text("Git checked")
                Text(repository.checkedAt, style: .relative)
            }
            .scaledFont(8).foregroundStyle(.tertiary)
            .accessibilityElement(children: .combine)
        }
        .padding(7)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.nSurface.opacity(0.72)))
    }

    private func repositoryEvidenceLine(
        label: String,
        value: String,
        detail: String,
        systemImage: String
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: systemImage)
                .scaledFont(9).foregroundStyle(.secondary).frame(width: 11)
            Text(verbatim: label)
                .scaledFont(8, weight: .bold).foregroundStyle(.secondary)
                .frame(width: 96, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: value)
                    .scaledFont(10, weight: .semibold, design: .monospaced)
                    .lineLimit(1).truncationMode(.middle)
                Text(verbatim: detail)
                    .scaledFont(8).foregroundStyle(.tertiary)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func sourceDetail(_ repository: ChangesRepositoryEvidence) -> String {
        let path = (repository.worktreePath as NSString).abbreviatingWithTildeInPath
        guard let count = repository.uncommittedCount else {
            return path + " · source file state unavailable at last check"
        }
        guard count > 0 else { return path + " · source worktree clean at last check" }
        return path + " · \(count) uncommitted source change\(count == 1 ? "" : "s")"
    }

    private func relationshipDetail(
        _ repository: ChangesRepositoryEvidence,
        hasUnprovedMutationWork: Bool
    ) -> String {
        guard repository.relationship.isIncluded else { return repository.relationship.label }
        var caveats: [String] = []
        if let count = repository.uncommittedCount {
            if count > 0 {
                caveats.append(
                    "Source HEAD comparison excludes \(count) uncommitted source change\(count == 1 ? "" : "s")")
            }
        } else {
            caveats.append("Source file state unavailable")
        }
        if hasUnprovedMutationWork {
            caveats.append("observed file work not proven included")
        }
        guard !caveats.isEmpty else { return repository.relationship.label }
        return ([repository.relationship.label] + caveats).joined(separator: " · ")
    }

    private func conversationHasUnprovedMutation(
        _ conversation: ChangesConversationPresentation
    ) -> Bool {
        conversation.work.contains {
            changesWorkHasUnprovedMutation(
                $0,
                fallbackRepository: conversation.repository)
        }
    }

    private func conversationStatusDescription(
        _ conversation: ChangesConversationPresentation
    ) -> String {
        if activeWorkspace.runningConversations.contains(conversation.id)
            || conversation.summary.hasRunningDelegate {
            return "Agent still working"
        }
        if conversation.summary.awaitingQuestion { return "Agent needs your answer" }
        if conversation.summary.errored { return "Last turn failed" }
        if conversation.summary.armedWaitSummary != nil { return "Conversation waiting" }
        guard let repository = conversation.repository else {
            return "Repository checkout not captured"
        }
        return relationshipDetail(
            repository,
            hasUnprovedMutationWork: conversationHasUnprovedMutation(conversation))
    }

    private func conversationAccessibilityValue(
        _ conversation: ChangesConversationPresentation,
        expanded: Bool
    ) -> String {
        let disclosure = expanded ? "Expanded" : "Collapsed"
        let scope = conversation.isCurrent ? "Current Conversation" : "Other Conversation"
        let files = conversation.work.isEmpty
            ? "No captured work record"
            : "\(conversation.mutationFileCount) changed, \(conversation.observedFileCount) observed"
        return [scope, disclosure, conversationStatusDescription(conversation), files]
            .joined(separator: ". ")
    }

    private var noCapturedWork: some View {
        VStack(alignment: .leading, spacing: 3) {
            Label("No work record was captured.", systemImage: "tray")
                .scaledFont(10, weight: .semibold).foregroundStyle(.secondary)
            Text("Mechanician will not infer intent, authorship, or inclusion from a clean worktree.")
                .scaledFont(9).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(7)
    }

    private func workEvidence(
        _ work: ChangesWorkEvidence,
        conversationID: UUID,
        fallbackRepository: ChangesRepositoryEvidence?,
        showRecordHeading: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            if showRecordHeading {
                HStack(spacing: 5) {
                    Text("WORK RECORD")
                        .scaledFont(8, weight: .bold).foregroundStyle(.secondary)
                    if let turnID = work.turnID {
                        Text(verbatim: shortGitOID(turnID, length: 7))
                            .scaledFont(8, design: .monospaced).foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Text(work.capturedAt, style: .relative)
                        .scaledFont(8).foregroundStyle(.tertiary)
                }
            }
            if let repository = work.repository ?? fallbackRepository {
                repositoryEvidence(
                    repository,
                    hasUnprovedMutationWork: changesWorkHasUnprovedMutation(
                        work,
                        fallbackRepository: fallbackRepository))
            } else {
                Label("Repository checkout was not captured for this work record.",
                      systemImage: "questionmark.circle")
                    .scaledFont(9).foregroundStyle(.tertiary)
            }
            transcriptEvidenceBand(
                label: "Person Asked",
                systemImage: "person.crop.circle",
                evidence: work.personAsked,
                missing: "No exact request was captured for this work record.",
                claim: false)
            transcriptEvidenceBand(
                label: "Agent Reported",
                systemImage: "text.bubble",
                evidence: work.agentReported,
                missing: "No final agent report was captured for this work record.",
                claim: true)
            observedWorkBand(
                work.observedFiles,
                conversationID: conversationID,
                workID: work.id,
                repository: work.repository ?? fallbackRepository)
        }
    }

    private func transcriptEvidenceBand(
        label: String,
        systemImage: String,
        evidence: ChangesTranscriptEvidence?,
        missing: String,
        claim: Bool
    ) -> some View {
        evidenceBand(label: label, systemImage: systemImage) {
            if let evidence {
                Text(verbatim: evidence.text.isEmpty ? "(empty entry)" : evidence.text)
                    .scaledFont(10)
                    .foregroundStyle(.primary.opacity(0.86))
                    .lineLimit(5)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                HStack(spacing: 4) {
                    if claim {
                        Text("Agent claim · not Git evidence")
                    } else {
                        Text("Exact transcript entry")
                    }
                    if evidence.truncated {
                        Text("· bounded capture")
                    }
                }
                .scaledFont(8).foregroundStyle(.tertiary)
            } else {
                Text(verbatim: missing)
                    .scaledFont(9).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func observedWorkBand(
        _ files: [ChangesObservedFileEvidence],
        conversationID: UUID,
        workID: String,
        repository: ChangesRepositoryEvidence?
    ) -> some View {
        evidenceBand(label: "Observed Work", systemImage: "wrench.and.screwdriver") {
            if files.isEmpty {
                Text("No successful file-tool or repository mutation receipt was captured.")
                    .scaledFont(9).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(files) { file in
                    observedFileRow(
                        file,
                        conversationID: conversationID,
                        workID: workID,
                        repository: repository)
                }
            }
        }
    }

    private func evidenceBand<Content: View>(
        label: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: systemImage)
                .scaledFont(9).foregroundStyle(.secondary)
                .frame(width: 12, height: 13)
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: label.uppercased())
                    .scaledFont(8, weight: .bold).foregroundStyle(.secondary)
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func observedFileRow(
        _ file: ChangesObservedFileEvidence,
        conversationID: UUID,
        workID: String,
        repository: ChangesRepositoryEvidence?
    ) -> some View {
        let key = observedKey(conversationID: conversationID, workID: workID, fileID: file.id)
        let otherWorktreeNote = otherWorktreeStateNote(file, repository: repository)
        return Button {
            selectedObservedKey = key
            selectedTouchedPath = nil
            selectedGitKey = nil
            bridge.gitDiff = nil
        } label: {
            HStack(alignment: .top, spacing: 6) {
                Text(verbatim: operationGlyph(file.operation))
                    .scaledFont(10, weight: .bold, design: .monospaced)
                    .foregroundStyle(file.operation.isMutation ? Color.nInfoText : .secondary)
                    .frame(width: 12)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: file.name)
                        .scaledFont(10, weight: .medium).lineLimit(1)
                    Text(verbatim: (file.directory as NSString).abbreviatingWithTildeInPath)
                        .scaledFont(8).foregroundStyle(.tertiary)
                        .lineLimit(1).truncationMode(.head)
                    if let state = file.repositoryState {
                        Text(verbatim: state.label)
                            .scaledFont(8, weight: .medium)
                            .foregroundStyle(repositoryStateColor(state))
                            .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    } else if let otherWorktreeNote {
                        Text(verbatim: otherWorktreeNote)
                            .scaledFont(8, weight: .medium)
                            .foregroundStyle(.secondary)
                            .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 4)
                VStack(alignment: .trailing, spacing: 1) {
                    Text(verbatim: file.operation.label.uppercased())
                        .scaledFont(8, weight: .bold)
                        .foregroundStyle(file.operation.isMutation ? Color.nInfoText : .secondary)
                    Text(verbatim: file.provenance.label)
                        .scaledFont(8).foregroundStyle(.tertiary)
                        .multilineTextAlignment(.trailing).lineLimit(2)
                }
            }
            .contentShape(Rectangle())
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 5).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 5)
            .fill(selectedObservedKey == key ? Color.nAccent.opacity(0.18) : .clear))
        .help(file.path)
        .accessibilityLabel(Text(verbatim: "\(file.operation.label): \(file.name)"))
        .accessibilityValue(Text(verbatim: observedFileAccessibilityValue(
            file,
            repository: repository,
            selected: selectedObservedKey == key)))
        .accessibilityHint("Shows this evidence in the shared preview")
    }

    private func otherWorktreeStateNote(
        _ file: ChangesObservedFileEvidence,
        repository: ChangesRepositoryEvidence?
    ) -> String? {
        guard file.operation.isMutation,
              file.repositoryState == nil,
              let repository,
              !repository.worktreePath.isEmpty,
              bridge.git.belongs(to: bridge.cwd),
              bridge.git.isRepo,
              !bridge.git.repoRoot.isEmpty else { return nil }
        let sourceRoot = (repository.worktreePath as NSString).standardizingPath
        let currentRoot = (bridge.git.repoRoot as NSString).standardizingPath
        guard sourceRoot != currentRoot else { return nil }
        return "File state not checked · other worktree"
    }

    private func observedFileAccessibilityValue(
        _ file: ChangesObservedFileEvidence,
        repository: ChangesRepositoryEvidence?,
        selected: Bool
    ) -> String {
        let repositoryStatus: String
        if let state = file.repositoryState {
            repositoryStatus = state.label
        } else if let otherWorktreeNote = otherWorktreeStateNote(file, repository: repository) {
            repositoryStatus = otherWorktreeNote
        } else if file.operation.isMutation {
            repositoryStatus = "Repository file state not captured"
        } else {
            repositoryStatus = "Read receipt; no mutation claimed"
        }
        var parts = [file.path, repositoryStatus, file.provenance.label]
        if selected { parts.append("Selected") }
        return parts.joined(separator: ". ")
    }

    private var renderedConversations: [ChangesConversationPresentation] {
        [presentation.current].compactMap { $0 } + presentation.others
    }

    private var selectedObservedEvidence:
        (conversation: ChangesConversationPresentation,
         work: ChangesWorkEvidence,
         file: ChangesObservedFileEvidence)? {
        guard let selectedObservedKey else { return nil }
        for conversation in renderedConversations {
            for work in conversation.work {
                for file in work.observedFiles
                where observedKey(
                    conversationID: conversation.id,
                    workID: work.id,
                    fileID: file.id) == selectedObservedKey {
                    return (conversation, work, file)
                }
            }
        }
        return nil
    }

    private func observedKey(conversationID: UUID, workID: String, fileID: String) -> String {
        conversationID.uuidString + "\u{0}" + workID + "\u{0}" + fileID
    }

    private func operationGlyph(_ operation: ChangesObservedFileOperation) -> String {
        switch operation {
        case .read: return "R"
        case .edited: return "M"
        case .created: return "A"
        case .deleted: return "D"
        case .renamed: return "→"
        }
    }

    private func repositoryStateColor(_ state: ChangesFileRepositoryState) -> Color {
        switch state {
        case .uncommitted: return .nWarningText
        case .committed: return .nSuccessText
        case .noCurrentDiff, .unavailable: return .secondary
        case .outsideRepository, .notVersionControlled: return Color.secondary.opacity(0.72)
        }
    }

    private func repositoryState(
        for outcome: ConversationFileOutcome
    ) -> ChangesFileRepositoryState? {
        switch outcome {
        case .uncommitted(let status):
            return .uncommitted(indexStatus: nil, worktreeStatus: status)
        case .committed(let oid):
            return .committed(commitOID: oid, reachableFrom: [])
        case .readOnly:
            return nil
        case .noCurrentDiff:
            return .noCurrentDiff
        case .outsideRepository:
            return .outsideRepository
        case .notVersionControlled:
            return .notVersionControlled
        case .gitUnavailable:
            return .unavailable
        }
    }

    @ViewBuilder private var gitWorkspaceState: some View {
        switch bridge.git.probe {
        case .checking, .idle:
            Label("Checking Git status…", systemImage: "arrow.clockwise")
                .scaledFont(11).foregroundStyle(.secondary).padding(.horizontal, 6)
        case .notRepository:
            VStack(alignment: .leading, spacing: 5) {
                Label("Not under version control", systemImage: "folder")
                    .scaledFont(11, weight: .semibold).foregroundStyle(.secondary)
                Text("This folder is not a Git repository. Stage, commit, and push are unavailable.")
                    .scaledFont(10).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                Button("Recheck") { bridge.refreshGit() }
                    .buttonStyle(.plain).scaledFont(10).foregroundStyle(Color.nInfoText)
            }
            .padding(8)
            // A well the panel draws for itself. The inspector is the window background now, and
            // `nElevated` is within four 8-bit levels of it in Light Mode — this box would have been
            // an outline of nothing around three lines of grey text.
            .cardSurface(cornerRadius: 8)
        case .unavailable:
            if bridge.devToolIssue == nil {
                Label("Git status unavailable", systemImage: "exclamationmark.triangle")
                    .scaledFont(11).foregroundStyle(.secondary).padding(.horizontal, 6)
            }
        case .repository:
            EmptyView() // a stale repository snapshot never describes a different cwd
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .scaledFont(10, weight: .bold).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 2)
    }

    // MARK: - Git file section (staged / other repo changes)

    @ViewBuilder private func gitSection(_ title: String, _ files: [GitFile], staged: Bool) -> some View {
        sectionHeader(title)
        ForEach(files) { file in
            HStack(spacing: 6) {
                Text(file.statusCode(stagedSide: staged))
                    .scaledFont(11, design: .monospaced)
                    .foregroundStyle(color(for: file, staged: staged)).frame(width: 12)
                Text(file.displayPath)
                    .scaledFont(11).lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        selectedTouchedPath = nil
                        selectedObservedKey = nil
                        selectedGitKey = gitKey(file, staged: staged)
                        bridge.gitShowDiff(file, staged: staged)
                    }
                Text(file.statusName(stagedSide: staged))
                    .scaledFont(9, weight: .medium).foregroundStyle(.tertiary)
                if let activity = activity(for: file), shouldShowActivityBadge(for: file, staged: staged) {
                    Text("Touched here")
                        .scaledFont(9, weight: .medium)
                        .foregroundStyle(Color.nInfoText)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(Color.nAccent.opacity(0.14)))
                        .help("This conversation: \(activityBadge(activity))")
                        .accessibilityLabel("Touched in current Conversation")
                        .accessibilityValue(Text(verbatim: activityBadge(activity)))
                }
                Button { staged ? bridge.gitUnstage(file) : bridge.gitStage(file) }
                    label: { Image(systemName: staged ? "minus.circle" : "plus.circle") }
                    .buttonStyle(.borderless).help(staged ? "Unstage" : "Stage")
                    .disabled(bridge.devToolIssue != nil)
                    .accessibilityLabel(staged ? "Unstage" : "Stage")
            }
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 6)
                .fill(selectedGitKey == gitKey(file, staged: staged) ? Color.nAccent.opacity(0.18) : .clear))
        }
    }

    private func gitKey(_ file: GitFile, staged: Bool) -> String {
        "\(file.path)|\(staged ? "index" : "worktree")"
    }

    private func activityBadge(_ activity: AgentBridge.TouchedFile) -> String {
        if activity.edits > 0 {
            return "\(activity.edits) \(activity.edits == 1 ? "edit" : "edits")"
        }
        return "\(activity.reads) \(activity.reads == 1 ? "read" : "reads")"
    }

    // MARK: - Commit bar + diff pane (git)

    private var commitBar: some View {
        VStack(spacing: 6) {
            TextField("Commit message", text: $commitMessage, axis: .vertical)
                .textFieldStyle(.roundedBorder).lineLimit(1...3)
            Button {
                bridge.gitCommit(commitMessage); commitMessage = ""
            } label: {
                Text("Commit \(bridge.git.stagedFiles.count) file\(bridge.git.stagedFiles.count == 1 ? "" : "s")")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(PillButtonStyle(kind: .accent))
            .disabled(bridge.git.stagedFiles.isEmpty
                      || commitMessage.trimmingCharacters(in: .whitespaces).isEmpty
                      || bridge.devToolIssue != nil)
        }
        .padding(10)
    }

    /// The ONE preview view. Shows the selected session-touched file's reconstructed diff or
    /// read-only contents, else the selected git file's `git diff` — never two panes at once.
    @ViewBuilder private var diffPane: some View {
        if let sel = selectedTouchedPath, let f = touched.first(where: { $0.path == sel }) {
            if !f.diff.isEmpty {
                diffContent(title: f.name, ext: (f.path as NSString).pathExtension, text: f.diff)
            } else {
                filePreviewContent(file: f)
            }
        } else if let selected = selectedObservedEvidence {
            if let patch = selected.file.patch, !patch.isEmpty {
                VStack(spacing: 0) {
                    observedSourceHeader(
                        selected.conversation,
                        repository: selected.work.repository,
                        file: selected.file)
                    Divider()
                    if selected.file.patchWasTruncated {
                        Label("Captured patch was truncated", systemImage: "scissors")
                            .scaledFont(9).foregroundStyle(Color.nWarningText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                        Divider()
                    }
                    diffContent(
                        title: selected.file.name,
                        ext: (selected.file.path as NSString).pathExtension,
                        text: patch)
                }
            } else if let live = bridge.touchedFiles[selected.conversation.id]?
                .first(where: { $0.path == selected.file.path }) {
                VStack(spacing: 0) {
                    observedSourceHeader(
                        selected.conversation,
                        repository: selected.work.repository,
                        file: selected.file)
                    Divider()
                    filePreviewContent(file: live)
                }
            } else {
                observedEvidencePreview(
                    selected.file,
                    conversation: selected.conversation,
                    repository: selected.work.repository)
            }
        } else if let diff = bridge.gitDiff {
            diffContent(title: (diff.path as NSString).lastPathComponent,
                        ext: (diff.path as NSString).pathExtension,
                        text: diff.text.isEmpty ? "(no changes)" : diff.text)
        } else {
            Text("Select a changed file to see its diff")
                .scaledFont(11).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func observedSourceHeader(
        _ conversation: ChangesConversationPresentation,
        repository: ChangesRepositoryEvidence?,
        file: ChangesObservedFileEvidence
    ) -> some View {
        HStack(spacing: 5) {
            Text("From")
                .scaledFont(9).foregroundStyle(.tertiary)
            Text(verbatim: "“\(conversation.title)”")
                .scaledFont(9, weight: .semibold).lineLimit(1)
            if let source = (repository ?? conversation.repository)?.sourceLabel {
                Text("·")
                    .scaledFont(9).foregroundStyle(.tertiary)
                Text(verbatim: source)
                    .scaledFont(9, design: .monospaced).foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Text(verbatim: file.provenance.label)
                .scaledFont(8).foregroundStyle(.tertiary).lineLimit(1)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
    }

    @ViewBuilder private func observedEvidencePreview(
        _ file: ChangesObservedFileEvidence,
        conversation: ChangesConversationPresentation,
        repository: ChangesRepositoryEvidence?
    ) -> some View {
        VStack(spacing: 0) {
            observedSourceHeader(conversation, repository: repository, file: file)
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                evidencePreviewField("PATH", file.path, monospaced: true)
                evidencePreviewField("OPERATION", file.operation.label)
                evidencePreviewField("ATTRIBUTION", file.provenance.label)
                if let state = file.repositoryState {
                    evidencePreviewField("REPOSITORY STATE", state.label)
                } else if let note = otherWorktreeStateNote(file, repository: repository) {
                    evidencePreviewField("REPOSITORY STATE", note)
                }
                if let before = file.beforeDigest {
                    evidencePreviewField("BEFORE DIGEST", before, monospaced: true)
                }
                if let after = file.afterDigest {
                    evidencePreviewField("AFTER DIGEST", after, monospaced: true)
                }
                Text("No bounded patch was captured for this receipt. Mechanician will not reconstruct one from newer filesystem bytes.")
                    .scaledFont(9).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func evidencePreviewField(
        _ label: String,
        _ value: String,
        monospaced: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: label)
                .scaledFont(8, weight: .bold).foregroundStyle(.secondary)
            Text(verbatim: value)
                .scaledFont(10, design: monospaced ? .monospaced : .default)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private func filePreviewContent(file: AgentBridge.TouchedFile) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(file.name).scaledFont(11, weight: .bold).lineLimit(1).truncationMode(.middle)
                Spacer()
                Text("read-only preview").scaledFont(10).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            Divider()
            ScrollView([.horizontal, .vertical]) {
                // One Text per line, exactly like the diff pane below. A single Text holding the
                // whole file grows one text layer thousands of points tall, and past that size the
                // compositor draws nothing at all — which is why previewing a large source file
                // (AgentBridge.swift, agentd.mjs) showed an empty pane instead of its contents.
                // Lazy so a long file realizes only the rows on screen.
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(
                        Array(Self.previewLines(Self.previewText(for: file.path)).enumerated()),
                        id: \.offset
                    ) { _, line in
                        Text(line.isEmpty ? " " : line)
                            .scaledFont(11, design: .monospaced)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                }
                .padding(8)
            }
        }
    }

    /// Split a preview into renderable lines, bounded so an enormous file cannot realize an
    /// unbounded row count. The byte clip in `previewText` is not sufficient on its own: 160 KB of
    /// source is still thousands of lines.
    static func previewLines(_ text: String, maxLines: Int = 5_000) -> [String] {
        let lines = text.components(separatedBy: "\n")
        guard lines.count > maxLines else { return lines }
        return Array(lines.prefix(maxLines)) + ["", "… preview truncated …"]
    }

    static func previewText(for path: String) -> String {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else { return "File no longer exists." }
        let limit = 160_000
        guard let preview = boundedPreviewData(at: url, maximumBytes: limit) else {
            return "Could not read file."
        }
        let data = preview.data
        if data.isEmpty { return "(empty file)" }
        let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .utf16)
            ?? String(data: data, encoding: .isoLatin1)
        guard let text else { return "Binary file preview is not available." }
        return preview.isTruncated ? text + "\n\n… preview truncated …" : text
    }

    private struct BoundedPreviewData {
        var data: Data
        let isTruncated: Bool
    }

    /// Workspace files can change while a Changes preview is on screen. Read a bounded copy from
    /// one descriptor so a truncate cannot invalidate a later memory-mapped access.
    private static func boundedPreviewData(at url: URL, maximumBytes: Int) -> BoundedPreviewData? {
        let descriptor = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        }
        guard descriptor >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }

        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_size >= 0 else {
            return nil
        }

        var data = Data()
        let limit = maximumBytes + 1
        while data.count < limit {
            let count = min(64 * 1_024, limit - data.count)
            do {
                guard let chunk = try handle.read(upToCount: count), !chunk.isEmpty else { break }
                data.append(chunk)
            } catch {
                return nil
            }
        }
        let isTruncated = data.count > maximumBytes || metadata.st_size > off_t(maximumBytes)
        if data.count > maximumBytes { data.removeLast(data.count - maximumBytes) }
        return BoundedPreviewData(data: data, isTruncated: isTruncated)
    }

    @ViewBuilder private func diffContent(title: String, ext: String, text: String) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).scaledFont(11, weight: .bold).lineLimit(1).truncationMode(.middle)
                Spacer()
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            Divider()
            ScrollView([.horizontal, .vertical]) {
                VStack(alignment: .leading, spacing: 0) {
                    let lines = text.components(separatedBy: "\n")
                    let language = SyntaxHighlighter.canonicalLanguage(ext)
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        let (attr, bg) = SyntaxHighlighter.diffLine(line.isEmpty ? " " : line,
                                                                    language: language, fontSize: 11 * uiScale)
                        Text(attr)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 3).background(bg)
                    }
                }
                .padding(8)
            }
            .textSelection(.enabled)
        }
    }

    // MARK: - Dev-tools banner (git can't run)

    @ViewBuilder private func gitWriteToolBanner(_ issue: DevToolIssue) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: "info.circle.fill").foregroundStyle(Color.nWarningText)
            Text(issue == .xcodeLicense
                 ? "Accept the Xcode license to stage, commit, or push. Diffs remain available."
                 : "Install Command Line Tools to stage, commit, or push. Diffs remain available.")
                .scaledFont(10).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            if issue == .xcodeLicense {
                Button("Accept…") { bridge.acceptXcodeLicense() }
                    .disabled(bridge.acceptingLicense)
            } else {
                Button("Install…") { bridge.installCommandLineTools() }
            }
        }
        .buttonStyle(.plain)
        .scaledFont(10, weight: .medium)
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.10)))
    }

    @ViewBuilder private func devToolBanner(_ issue: DevToolIssue) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill").scaledFont(26)
                .foregroundStyle(Color.nWarningText)
            switch issue {
            case .xcodeLicense:
                Text("Xcode license not accepted").scaledFont(13, weight: .semibold)
                Text("Git and the build tools can't run until you accept the Xcode license. This needs administrator approval.")
                    .scaledFont(11).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button { bridge.acceptXcodeLicense() } label: {
                    if bridge.acceptingLicense {
                        HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Waiting for approval…") }
                    } else {
                        Label("Accept Xcode License…", systemImage: "checkmark.seal")
                    }
                }
                .buttonStyle(PillButtonStyle(kind: .accent)).disabled(bridge.acceptingLicense)
            case .devTools:
                Text("Developer tools unavailable").scaledFont(13, weight: .semibold)
                Text("The command line developer tools aren't installed, or the active developer directory is invalid.")
                    .scaledFont(11).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button { bridge.installCommandLineTools() } label: {
                    Label("Install Command Line Tools…", systemImage: "arrow.down.circle")
                }
                .buttonStyle(PillButtonStyle(kind: .accent))
            }
            if !bridge.devToolMessage.isEmpty {
                Text(bridge.devToolMessage)
                    .scaledFont(10, design: .monospaced).foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center).textSelection(.enabled).padding(.top, 2)
            }
            Button("Recheck") { bridge.refreshGit() }
                .buttonStyle(.plain).scaledFont(11).foregroundStyle(Color.nInfoText)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func color(for file: GitFile, staged: Bool) -> Color {
        switch file.statusCode(stagedSide: staged) {
        case "A": return .nSuccessText
        case "M": return .nWarningText
        case "D": return .nErrorText
        case "?": return .secondary
        default: return .primary
        }
    }
}

/// Correlate an absolute provider-observed path with Git's repo-root-relative rename-aware paths.
/// Kept outside the view so current-checkout status and Conversation evidence can be reconciled
/// without claiming that a path match proves authorship.
func matchingGitFile(forAbsolute path: String, in git: GitStatus) -> GitFile? {
    guard git.isRepo else { return nil }
    return git.files.first { file in
        file.operationPaths.contains { git.absolutePath($0) == path }
    }
}
