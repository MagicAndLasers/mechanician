import Foundation
import XCTest
@testable import Mechanician

@MainActor
final class ConversationSidebarTests: XCTestCase {
    func testProjectedSelectionRetainsOnlyTheLatestValidSingleClick() {
        let current = UUID()
        let first = UUID()
        let latest = UUID()

        XCTAssertEqual(
            ConversationSidebarInteractionPolicy.selectionAction(
                selection: [first],
                currentID: current,
                pendingSelectionID: nil,
                storeIsReady: false,
                targetIsValid: true),
            .retainUntilReady(first))
        XCTAssertEqual(
            ConversationSidebarInteractionPolicy.selectionAction(
                selection: [latest],
                currentID: current,
                pendingSelectionID: nil,
                storeIsReady: false,
                targetIsValid: true),
            .retainUntilReady(latest))
        XCTAssertEqual(
            ConversationSidebarInteractionPolicy.selectionAction(
                selection: [latest],
                currentID: current,
                pendingSelectionID: nil,
                storeIsReady: true,
                targetIsValid: true),
            .select(latest, cancelPending: false))
    }

    func testReturningToCurrentConversationCancelsPendingHydration() {
        let current = UUID()
        let loading = UUID()

        XCTAssertEqual(
            ConversationSidebarInteractionPolicy.selectionAction(
                selection: [current],
                currentID: current,
                pendingSelectionID: loading,
                storeIsReady: true,
                targetIsValid: true),
            .cancelPending)
        XCTAssertEqual(
            ConversationSidebarInteractionPolicy.selectionAction(
                selection: [current],
                currentID: current,
                pendingSelectionID: nil,
                storeIsReady: true,
                targetIsValid: true),
            .none)
        XCTAssertEqual(
            ConversationSidebarInteractionPolicy.selectionAction(
                selection: [loading],
                currentID: current,
                pendingSelectionID: nil,
                storeIsReady: false,
                targetIsValid: false),
            .none,
            "A stale projected row is never promoted to an authoritative selection.")
    }

    func testAThirdConversationCancelsPriorHydrationBeforeStartingItsSelection() {
        let current = UUID()
        let loading = UUID()
        let latest = UUID()

        XCTAssertEqual(
            ConversationSidebarInteractionPolicy.selectionAction(
                selection: [latest],
                currentID: current,
                pendingSelectionID: loading,
                storeIsReady: true,
                targetIsValid: true),
            .select(latest, cancelPending: true),
            "The old decode must be ineligible before the latest selection starts.")
    }

    func testExplicitPreReadyNavigationSupersedesAnOlderProjectedClick() {
        XCTAssertTrue(ConversationSidebarInteractionPolicy.projectedSelectionIsCurrent(
            capturedNavigationGeneration: 4,
            currentNavigationGeneration: 4))
        XCTAssertFalse(ConversationSidebarInteractionPolicy.projectedSelectionIsCurrent(
            capturedNavigationGeneration: 4,
            currentNavigationGeneration: 5),
            "A later pre-ready ⌘N/navigation must supersede the projected-row click.")
    }

    func testSearchFilteredSidebarDisablesPartialReordering() {
        XCTAssertTrue(ConversationSidebarInteractionPolicy.allowsReordering(query: ""))
        XCTAssertTrue(ConversationSidebarInteractionPolicy.allowsReordering(query: "  \n"))
        XCTAssertFalse(ConversationSidebarInteractionPolicy.allowsReordering(query: "needle"))
        XCTAssertFalse(ConversationSidebarInteractionPolicy.allowsReordering(query: " needle "))
        XCTAssertFalse(
            ConversationSidebarInteractionPolicy.allowsReordering(
                query: "",
                filter: .unread),
            "A state-filtered subset cannot truthfully accept a full sidebar reorder.")
        XCTAssertFalse(
            ConversationSidebarInteractionPolicy.allowsReordering(
                query: "",
                filter: .working))
    }

    func testConversationFilterRestoresKnownPreferencesAndDefaultsUnknownValuesToAll() {
        XCTAssertEqual(ConversationSidebarFilter.restored(from: "all"), .all)
        XCTAssertEqual(ConversationSidebarFilter.restored(from: "unread"), .unread)
        XCTAssertEqual(ConversationSidebarFilter.restored(from: "working"), .working)
        XCTAssertEqual(
            ConversationSidebarFilter.restored(from: "retired-filter"),
            .all,
            "A future or damaged preference must not hide every conversation.")
    }

    func testConversationFilterHeaderPresentationKeepsItsActiveStateAndAccessibilityContract() {
        XCTAssertFalse(ConversationSidebarFilter.all.isActive)
        XCTAssertTrue(ConversationSidebarFilter.unread.isActive)
        XCTAssertTrue(ConversationSidebarFilter.working.isActive)

        XCTAssertEqual(
            ConversationSidebarFilterPresentation.accessibilityIdentifier,
            "conversationSidebar.filter")
        XCTAssertEqual(
            ConversationSidebarFilterPresentation.symbolName,
            "line.3.horizontal.decrease")
        XCTAssertEqual(ConversationSidebarFilterPresentation.headerActionSize, 34)
        XCTAssertEqual(
            ConversationSidebarFilterPresentation.accessibilityLabel,
            "Filter conversations")
        XCTAssertEqual(
            ConversationSidebarFilterPresentation.accessibilityHint,
            "Choose which conversations appear in the sidebar")
        XCTAssertEqual(
            ConversationSidebarFilterPresentation.help(for: .all),
            "Filter conversations")
        XCTAssertEqual(
            ConversationSidebarFilterPresentation.help(for: .unread),
            "Filter conversations — showing unread")
        XCTAssertEqual(
            ConversationSidebarFilterPresentation.help(for: .working),
            "Filter conversations — showing actively working")
        XCTAssertEqual(
            ConversationSidebarFilterPresentation.menuOptionAccessibilityLabel(for: .all),
            "Show all conversations")
        XCTAssertEqual(
            ConversationSidebarFilterPresentation.menuOptionAccessibilityLabel(for: .unread),
            "Show unread conversations")
        XCTAssertEqual(
            ConversationSidebarFilterPresentation.menuOptionAccessibilityLabel(for: .working),
            "Show actively working conversations")
        XCTAssertEqual(
            ConversationSidebarFilterPresentation.selectionAccessibilityValue(selected: true),
            "Selected")
        XCTAssertEqual(
            ConversationSidebarFilterPresentation.selectionAccessibilityValue(selected: false),
            "Not selected")
    }

    func testConversationHeaderActionsNameTheirOverflowAndNewPurposes() {
        XCTAssertEqual(
            ConversationSidebarHeaderActionPresentation.moreActionsAccessibilityIdentifier,
            "conversationSidebar.moreActions")
        XCTAssertEqual(
            ConversationSidebarHeaderActionPresentation.moreActionsSymbolName,
            "ellipsis.circle")
        XCTAssertEqual(
            ConversationSidebarHeaderActionPresentation.moreActionsAccessibilityLabel,
            "Conversation actions")
        XCTAssertEqual(
            ConversationSidebarHeaderActionPresentation.moreActionsAccessibilityHint,
            "Select visible conversations or delete all conversations")
        XCTAssertEqual(
            ConversationSidebarHeaderActionPresentation.moreActionsHelp,
            "Conversation actions")

        XCTAssertEqual(
            ConversationSidebarHeaderActionPresentation.selectAllAccessibilityIdentifier,
            "conversationSidebar.selectAll")
        XCTAssertEqual(
            ConversationSidebarHeaderActionPresentation.selectAllAccessibilityLabel,
            "Select all visible conversations")
        XCTAssertEqual(
            ConversationSidebarHeaderActionPresentation.selectAllAccessibilityHint,
            "Selects every conversation currently shown in the sidebar")

        XCTAssertEqual(
            ConversationSidebarHeaderActionPresentation.deleteAllAccessibilityIdentifier,
            "conversationSidebar.deleteAll")
        XCTAssertEqual(
            ConversationSidebarHeaderActionPresentation.deleteAllAccessibilityLabel,
            "Delete all conversations")
        XCTAssertEqual(
            ConversationSidebarHeaderActionPresentation.deleteAllAccessibilityHint,
            "Opens a confirmation before deleting every conversation")
        XCTAssertEqual(
            ConversationSidebarHeaderActionPresentation.deleteAllHelp,
            "Delete all conversations…")

        XCTAssertEqual(
            ConversationSidebarHeaderActionPresentation.newConversationAccessibilityIdentifier,
            "conversationSidebar.newConversation")
        XCTAssertEqual(
            ConversationSidebarHeaderActionPresentation.newConversationSymbolName,
            "square.and.pencil")
        XCTAssertEqual(
            ConversationSidebarHeaderActionPresentation.newConversationAccessibilityLabel,
            "New conversation")
        XCTAssertEqual(
            ConversationSidebarHeaderActionPresentation.newConversationAccessibilityHint,
            "Create a new conversation in this workspace")
        XCTAssertEqual(
            ConversationSidebarHeaderActionPresentation.newConversationHelp,
            "New conversation")
    }

    func testStateFiltersComposeWithScopeSearchAndTheLiveRunningSet() {
        let local = Project(name: "Local", cwd: "/private/tmp/sidebar-filter-local")
        let foreign = Project(name: "Foreign", cwd: "/private/tmp/sidebar-filter-foreign")

        var unread = ConversationSummary(conversation(
            title: "Needle unread",
            cwd: local.cwd,
            projectID: local.id))
        unread.unread = true
        let working = ConversationSummary(conversation(
            title: "Needle working",
            cwd: local.cwd,
            projectID: local.id))
        var activeDelegate = ConversationSummary(conversation(
            title: "Needle delegated work",
            cwd: local.cwd,
            projectID: local.id))
        activeDelegate.hasRunningDelegate = true
        // Cold-load recovery terminalizes an abandoned delegate before it reaches a summary. This
        // normal row models that recovered result, so the filter cannot retain a stale spinner.
        let recoveredDelegate = ConversationSummary(conversation(
            title: "Needle recovered delegate",
            cwd: local.cwd,
            projectID: local.id))
        let foreignWorking = ConversationSummary(conversation(
            title: "Needle foreign",
            cwd: foreign.cwd,
            projectID: foreign.id))

        let summaries = [foreignWorking, unread, working, activeDelegate, recoveredDelegate]
        let unreadSnapshot = ConversationSidebarSnapshot.make(
            orderedConversations: summaries,
            scope: .project(local.id),
            projects: [local, foreign],
            query: "needle",
            filter: .unread,
            runningConversationIDs: [working.id, foreignWorking.id])
        XCTAssertEqual(unreadSnapshot.scopedCount, 4)
        XCTAssertEqual(unreadSnapshot.filteredCount, 1)
        XCTAssertEqual(unreadSnapshot.visibleConversations.map(\.id), [unread.id])

        let workingSnapshot = ConversationSidebarSnapshot.make(
            orderedConversations: summaries,
            scope: .project(local.id),
            projects: [local, foreign],
            query: "needle",
            filter: .working,
            runningConversationIDs: [working.id, foreignWorking.id])
        XCTAssertEqual(workingSnapshot.filteredCount, 2)
        XCTAssertEqual(
            workingSnapshot.visibleConversations.map(\.id),
            [working.id, activeDelegate.id])
        XCTAssertFalse(
            workingSnapshot.visibleConversations.contains(where: { $0.id == recoveredDelegate.id }),
            "A delegate terminalized during cold recovery must not remain in the Working filter.")
    }

    func testStateFilterEmptyPresentationDoesNotOfferANewConversation() {
        XCTAssertEqual(
            ConversationSidebarEmptyPresentation.message(query: "", filter: .unread),
            "No unread conversations")
        XCTAssertEqual(
            ConversationSidebarEmptyPresentation.message(query: "", filter: .working),
            "No actively working conversations")
        XCTAssertEqual(
            ConversationSidebarEmptyPresentation.message(query: "needle", filter: .working),
            "No matches")
        XCTAssertTrue(
            ConversationSidebarEmptyPresentation.showsNewConversationAction(
                query: " \n ",
                filter: .all))
        XCTAssertFalse(
            ConversationSidebarEmptyPresentation.showsNewConversationAction(
                query: "",
                filter: .unread))
        XCTAssertFalse(
            ConversationSidebarEmptyPresentation.showsNewConversationAction(
                query: "needle",
                filter: .all))
    }

    func testFilteringDropsHiddenSelectionsWithoutCancellingAnUnrelatedOpening() {
        let visible = UUID()
        let hidden = UUID()
        let openingElsewhere = UUID()
        let selection = Set([visible, hidden])
        let removed = selection.subtracting(
            ConversationSidebarInteractionPolicy.selectionAfterFiltering(
                selection,
                visibleConversationIDs: [visible]))

        XCTAssertEqual(
            ConversationSidebarInteractionPolicy.selectionAfterFiltering(
                selection,
                visibleConversationIDs: [visible]),
            [visible],
            "A narrowed sidebar must not retain a hidden row for later bulk commands.")
        XCTAssertTrue(
            ConversationSidebarInteractionPolicy.shouldCancelPendingSidebarSelection(
                removedSelection: removed,
                pendingSelectionID: hidden))
        XCTAssertTrue(
            ConversationSidebarInteractionPolicy.shouldClearPreReadySidebarSelection(
                removedSelection: removed,
                pendingSelectionID: hidden))
        XCTAssertFalse(
            ConversationSidebarInteractionPolicy.shouldCancelPendingSidebarSelection(
                removedSelection: removed,
                pendingSelectionID: openingElsewhere),
            "A filter must not cancel an unrelated initial hydration.")
        XCTAssertFalse(
            ConversationSidebarInteractionPolicy.shouldClearPreReadySidebarSelection(
                removedSelection: removed,
                pendingSelectionID: visible))
    }

    func testProjectionRebuildShowsLoadingInsteadOfZeroConversationLossState() {
        XCTAssertTrue(
            ConversationSidebarLoadPresentation.showsLoading(isReady: false, rowCount: 0))
        XCTAssertEqual(
            ConversationSidebarLoadPresentation.countLabel(isReady: false, rowCount: 0),
            "Loading conversations…")
        XCTAssertEqual(
            ConversationSidebarLoadPresentation.countLabel(isReady: false, rowCount: 12),
            "12 conversations")
        XCTAssertEqual(
            ConversationSidebarLoadPresentation.countLabel(isReady: true, rowCount: 0),
            "0 conversations")
    }

    func testWorkspaceScopeResolvesTheCompleteIdentityMatrix() {
        let topic = Project(name: "Topic")
        let first = Project(name: "First", cwd: "/private/tmp/first/repo")
        let second = Project(name: "Second", cwd: "/private/tmp/second/repo")
        let projects = [topic, first, second]

        XCTAssertEqual(
            WorkspaceScope.resolve(projectID: nil, cwd: "", projects: projects),
            .home)
        XCTAssertEqual(
            WorkspaceScope.resolve(projectID: topic.id, cwd: "", projects: projects),
            .project(topic.id))
        XCTAssertEqual(
            WorkspaceScope.resolve(projectID: nil, cwd: first.cwd, projects: projects),
            .project(first.id))
        XCTAssertEqual(
            WorkspaceScope.resolve(projectID: first.id, cwd: second.cwd, projects: projects),
            .project(first.id),
            "A valid persisted id is authoritative over stale cwd metadata.")
        XCTAssertEqual(
            WorkspaceScope.resolve(projectID: second.id, cwd: first.cwd, projects: projects),
            .project(second.id))
        XCTAssertFalse(
            WorkspaceScope.project(first.id).contains(
                conversation(title: "Foreign stale cwd", cwd: first.cwd, projectID: second.id),
                projects: projects),
            "A foreign valid id must not fall through to the folder whose cwd it carries.")
        XCTAssertNil(
            WorkspaceScope.resolve(projectID: UUID(), cwd: first.cwd, projects: projects),
            "A dangling id must not fall through to another workspace by cwd.")
        XCTAssertNil(
            WorkspaceScope.resolve(projectID: nil, cwd: "/private/tmp/unknown", projects: projects))
        XCTAssertNil(
            WorkspaceScope.resolve(projectID: nil, cwd: " \n ", projects: projects))

        let duplicate = Project(name: "Duplicate", cwd: first.cwd)
        XCTAssertNil(
            WorkspaceScope.resolve(
                projectID: nil,
                cwd: first.cwd,
                projects: projects + [duplicate]),
            "Legacy cwd ownership must be unique, even if corrupt Project records collide.")
        XCTAssertEqual(
            WorkspaceScope.resolve(
                projectID: first.id,
                cwd: first.cwd,
                projects: projects + [duplicate]),
            .project(first.id),
            "An explicit valid id stays unambiguous despite duplicate legacy cwd evidence.")
        XCTAssertNotEqual(first.cwd, second.cwd)
        XCTAssertEqual(
            URL(fileURLWithPath: first.cwd).lastPathComponent,
            URL(fileURLWithPath: second.cwd).lastPathComponent,
            "The matrix must cover equal folder labels backed by distinct full paths.")
    }

    func testPreferredConversationHonorsExactScopeAndRequestedIdentity() {
        let destination = Project(name: "Destination", cwd: "/private/tmp/preferred-destination")
        let foreign = Project(name: "Foreign", cwd: "/private/tmp/preferred-foreign")
        let projects = [destination, foreign]
        let olderRequested = conversation(
            title: "Requested",
            cwd: "/stale",
            projectID: destination.id,
            updatedAt: Date(timeIntervalSince1970: 1))
        let newerLocal = conversation(
            title: "Newer local",
            cwd: destination.cwd,
            projectID: destination.id,
            updatedAt: Date(timeIntervalSince1970: 2))
        let newestForeign = conversation(
            title: "Foreign stale cwd",
            cwd: destination.cwd,
            projectID: foreign.id,
            updatedAt: Date(timeIntervalSince1970: 4))
        let dangling = conversation(
            title: "Dangling",
            cwd: destination.cwd,
            projectID: UUID(),
            updatedAt: Date(timeIntervalSince1970: 5))
        let scope = WorkspaceScope.project(destination.id)
        let candidates = [newestForeign, dangling, newerLocal, olderRequested]

        XCTAssertEqual(
            scope.preferredConversation(
                requestedID: olderRequested.id,
                among: candidates,
                projects: projects)?.id,
            olderRequested.id,
            "An exact eligible request beats a newer row in the same workspace.")
        XCTAssertEqual(
            scope.preferredConversation(
                requestedID: newestForeign.id,
                among: candidates,
                projects: projects)?.id,
            newerLocal.id,
            "A foreign requested id is rejected before the local recency fallback.")
        XCTAssertNil(
            scope.preferredConversation(
                requestedID: dangling.id,
                among: [newestForeign, dangling],
                projects: projects))

        let legacy = conversation(
            title: "Legacy",
            cwd: destination.cwd,
            projectID: nil,
            updatedAt: Date(timeIntervalSince1970: 3))
        XCTAssertEqual(
            scope.preferredConversation(among: [legacy], projects: projects)?.id,
            legacy.id)
        let duplicate = Project(name: "Duplicate", cwd: destination.cwd)
        XCTAssertNil(
            scope.preferredConversation(
                among: [legacy],
                projects: projects + [duplicate]),
            "Legacy cwd evidence is ineligible when Project ownership is ambiguous.")
    }

    func testSidebarSnapshotScopesBeforeSearchingAndKeepsTheUnsearchedCount() {
        let local = Project(name: "Local", cwd: "/private/tmp/local")
        let foreign = Project(name: "Foreign", cwd: "/private/tmp/foreign")
        let localTitle = conversation(
            title: "Needle in title",
            cwd: local.cwd,
            projectID: local.id)
        let localMessage = conversation(
            title: "Message match",
            cwd: local.cwd,
            projectID: local.id,
            message: "The NEEDLE is in this message")
        let localOther = conversation(
            title: "No match",
            cwd: local.cwd,
            projectID: local.id)
        let foreignMatch = conversation(
            title: "Needle in another workspace",
            cwd: foreign.cwd,
            projectID: foreign.id,
            message: "needle")
        let ordered = [foreignMatch, localTitle, localMessage, localOther]

        let snapshot = ConversationSidebarSnapshot.make(
            orderedConversations: ordered.map(ConversationSummary.init),
            scope: .project(local.id),
            projects: [local, foreign],
            query: "  nEeDlE  ")

        XCTAssertEqual(snapshot.scopedCount, 3)
        XCTAssertEqual(snapshot.scopedConversations.map(\.id), [localTitle.id, localMessage.id, localOther.id])
        XCTAssertEqual(snapshot.visibleConversations.map(\.id), [localTitle.id, localMessage.id])
        XCTAssertFalse(snapshot.visibleConversations.contains(where: { $0.id == foreignMatch.id }))

        let blank = ConversationSidebarSnapshot.make(
            orderedConversations: ordered.map(ConversationSummary.init),
            scope: .project(local.id),
            projects: [local, foreign],
            query: "   ")
        XCTAssertEqual(blank.visibleConversations.map(\.id), blank.scopedConversations.map(\.id))

        let unresolved = ConversationSidebarSnapshot.make(
            orderedConversations: ordered.map(ConversationSummary.init),
            scope: nil,
            projects: [local, foreign],
            query: "")
        XCTAssertEqual(unresolved.scopedCount, 0)
        XCTAssertTrue(unresolved.visibleConversations.isEmpty)
    }

    func testSidebarScopesHomeTopicFolderAndLegacyConversationsWithoutCwdLeakage() {
        let topic = Project(name: "Topic")
        let folder = Project(name: "Folder", cwd: "/private/tmp/folder")
        let projects = [topic, folder]
        let home = conversation(title: "Home", cwd: "", projectID: nil)
        let topicConversation = conversation(title: "Topic", cwd: "", projectID: topic.id)
        let folderConversation = conversation(title: "Folder", cwd: folder.cwd, projectID: folder.id)
        let staleFolder = conversation(title: "Stale", cwd: "/stale", projectID: folder.id)
        let legacyFolder = conversation(title: "Legacy", cwd: folder.cwd, projectID: nil)
        let dangling = conversation(title: "Dangling", cwd: folder.cwd, projectID: UUID())
        let all = [home, topicConversation, folderConversation, staleFolder, legacyFolder, dangling]

        let homeRows = ConversationSidebarSnapshot.make(
            orderedConversations: all.map(ConversationSummary.init),
            scope: .home,
            projects: projects,
            query: "")
        XCTAssertEqual(homeRows.visibleConversations.map(\.id), [home.id])

        let topicRows = ConversationSidebarSnapshot.make(
            orderedConversations: all.map(ConversationSummary.init),
            scope: .project(topic.id),
            projects: projects,
            query: "")
        XCTAssertEqual(topicRows.visibleConversations.map(\.id), [topicConversation.id])

        let folderRows = ConversationSidebarSnapshot.make(
            orderedConversations: all.map(ConversationSummary.init),
            scope: .project(folder.id),
            projects: projects,
            query: "")
        XCTAssertEqual(
            folderRows.visibleConversations.map(\.id),
            [folderConversation.id, staleFolder.id, legacyFolder.id])
    }

    func testWorkspaceBindingRepairIsBoundedAndIdempotent() throws {
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("Mechanician-sidebar-repair-\(UUID().uuidString)", isDirectory: true)
        let projects = ProjectStore(appSupportBaseOverride: support)
        let conversations = ConversationStore(appSupportBaseOverride: support, watchesDirectory: false)
        defer {
            projects.flushSaves()
            conversations.flushSaves()
            try? FileManager.default.removeItem(at: support)
        }

        let topic = Project(name: "Topic")
        let folder = Project(name: "Folder", cwd: "/private/tmp/canonical")
        let duplicateA = Project(name: "Duplicate A", cwd: "/private/tmp/duplicate")
        let duplicateB = Project(name: "Duplicate B", cwd: "/private/tmp/duplicate")
        [topic, folder, duplicateA, duplicateB].forEach(projects.upsert)

        let stale = conversation(title: "Stale", cwd: "/old", projectID: folder.id)
        let staleTopic = conversation(title: "Stale topic", cwd: "/old-topic", projectID: topic.id)
        let legacy = conversation(title: "Legacy", cwd: "  \(folder.cwd)  ", projectID: nil)
        let dangling = conversation(title: "Dangling", cwd: folder.cwd, projectID: UUID())
        let unknown = conversation(title: "Unknown", cwd: "/private/tmp/unknown", projectID: nil)
        let ambiguous = conversation(title: "Ambiguous", cwd: duplicateA.cwd, projectID: nil)
        let home = conversation(title: "Home", cwd: "", projectID: nil)
        [stale, staleTopic, legacy, dangling, unknown, ambiguous, home].forEach(conversations.upsert)

        XCTAssertEqual(
            projects.repairConversationWorkspaceBindings(conversations: conversations),
            3)
        XCTAssertEqual(conversations.conversation(stale.id)?.projectID, folder.id)
        XCTAssertEqual(conversations.conversation(stale.id)?.cwd, folder.cwd)
        XCTAssertEqual(conversations.conversation(staleTopic.id)?.projectID, topic.id)
        XCTAssertEqual(conversations.conversation(staleTopic.id)?.cwd, "")
        XCTAssertEqual(conversations.conversation(legacy.id)?.projectID, folder.id)
        XCTAssertEqual(conversations.conversation(legacy.id)?.cwd, folder.cwd)
        XCTAssertEqual(conversations.conversation(dangling.id)?.projectID, dangling.projectID)
        XCTAssertEqual(conversations.conversation(dangling.id)?.cwd, dangling.cwd)
        XCTAssertEqual(conversations.conversation(unknown.id)?.projectID, unknown.projectID)
        XCTAssertEqual(conversations.conversation(unknown.id)?.cwd, unknown.cwd)
        XCTAssertEqual(conversations.conversation(ambiguous.id)?.projectID, ambiguous.projectID)
        XCTAssertEqual(conversations.conversation(ambiguous.id)?.cwd, ambiguous.cwd)
        XCTAssertEqual(conversations.conversation(home.id)?.projectID, home.projectID)
        XCTAssertEqual(conversations.conversation(home.id)?.cwd, home.cwd)
        XCTAssertEqual(
            projects.repairConversationWorkspaceBindings(conversations: conversations),
            0,
            "A second launch must not rewrite already canonical records.")
    }

    func testMigrationUsesOnlyLegacyNilIDRecordsAndNeverResurrectsDanglingWorkspace() throws {
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("Mechanician-sidebar-migration-\(UUID().uuidString)", isDirectory: true)
        let projects = ProjectStore(appSupportBaseOverride: support)
        let conversations = ConversationStore(appSupportBaseOverride: support, watchesDirectory: false)
        let suiteName = "Mechanician-sidebar-migration-defaults-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            projects.flushSaves()
            conversations.flushSaves()
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: support)
        }

        let removedID = UUID()
        let cwd = "/private/tmp/removed-workspace"
        let dangling = conversation(title: "Dangling", cwd: cwd, projectID: removedID)
        conversations.upsert(dangling)

        projects.migrateIfNeeded(conversations: conversations, defaults: defaults)
        XCTAssertTrue(projects.projects.isEmpty)
        XCTAssertEqual(conversations.conversation(dangling.id)?.projectID, removedID)

        let legacy = conversation(title: "Legacy", cwd: cwd, projectID: nil)
        conversations.upsert(legacy)
        projects.migrateIfNeeded(conversations: conversations, defaults: defaults)

        let migratedProject = try XCTUnwrap(projects.projects.first)
        XCTAssertEqual(migratedProject.cwd, cwd)
        XCTAssertEqual(conversations.conversation(legacy.id)?.projectID, migratedProject.id)
        XCTAssertEqual(
            conversations.conversation(dangling.id)?.projectID,
            removedID,
            "A dangling non-nil id must survive even when a legitimate legacy row shares its cwd.")
    }

    func testLocalSelectionRejectsForeignRecordsAndCanonicalizesStaleLocalCwd() throws {
        let destination = Project(
            name: "Selection destination",
            cwd: "/private/tmp/selection-destination-\(UUID().uuidString)")
        let foreign = Project(
            name: "Selection foreign",
            cwd: "/private/tmp/selection-foreign-\(UUID().uuidString)")
        let local = conversation(title: "Local", cwd: "/stale", projectID: destination.id)
        let foreignStale = conversation(
            title: "Foreign",
            cwd: destination.cwd,
            projectID: foreign.id)
        let dangling = conversation(
            title: "Dangling",
            cwd: destination.cwd,
            projectID: UUID())
        ProjectStore.shared.upsert(destination)
        ProjectStore.shared.upsert(foreign)
        [local, foreignStale, dangling].forEach(ConversationStore.shared.upsert)
        let previousLastLocation = UserDefaults.standard.string(forKey: lastLocationKey)
        let settings = FileManager.default.temporaryDirectory
            .appendingPathComponent("selection-settings-\(UUID().uuidString)", isDirectory: true)
        let bridge = AgentBridge(settingsBaseOverride: settings, environmentOverride: [:])
        bridge.cwd = destination.cwd
        bridge.projectID = nil
        defer {
            bridge.currentID = nil
            bridge.shutdown()
            [local, foreignStale, dangling].forEach {
                ConversationStore.shared.remove($0.id, permanently: true)
            }
            ProjectStore.shared.remove(destination.id)
            ProjectStore.shared.remove(foreign.id)
            ConversationStore.shared.flushSaves()
            ProjectStore.shared.flushSaves()
            if let previousLastLocation {
                UserDefaults.standard.set(previousLastLocation, forKey: lastLocationKey)
            } else {
                UserDefaults.standard.removeObject(forKey: lastLocationKey)
            }
            try? FileManager.default.removeItem(at: settings)
        }

        bridge.select(foreignStale.id, allowingWorkspaceChange: false)
        XCTAssertNil(bridge.currentID)
        bridge.select(dangling.id, allowingWorkspaceChange: false)
        XCTAssertNil(bridge.currentID)

        bridge.select(local.id, allowingWorkspaceChange: false)
        XCTAssertEqual(bridge.currentID, local.id)
        XCTAssertEqual(bridge.cwd, destination.cwd)
        XCTAssertNil(bridge.projectID, "Folder-backed windows retain their cwd representation.")
        XCTAssertEqual(ConversationStore.shared.conversation(local.id)?.cwd, destination.cwd)
        XCTAssertEqual(ConversationStore.shared.conversation(local.id)?.projectID, destination.id)

        bridge.select(foreignStale.id)
        XCTAssertEqual(bridge.currentID, foreignStale.id)
        XCTAssertEqual(bridge.cwd, foreign.cwd)
        XCTAssertNil(bridge.projectID)
        XCTAssertEqual(ConversationStore.shared.conversation(foreignStale.id)?.cwd, foreign.cwd)
    }

    func testEnteringFolderWorkspaceDoesNotAdoptForeignOrDanglingMatchingCwd() {
        let destination = Project(
            name: "Enter destination",
            cwd: "/private/tmp/enter-destination-\(UUID().uuidString)")
        let foreign = Project(
            name: "Enter foreign",
            cwd: "/private/tmp/enter-foreign-\(UUID().uuidString)")
        let local = conversation(
            title: "Local",
            cwd: "/stale-local",
            projectID: destination.id,
            updatedAt: Date(timeIntervalSince1970: 1))
        let foreignStale = conversation(
            title: "Foreign",
            cwd: destination.cwd,
            projectID: foreign.id,
            updatedAt: Date(timeIntervalSince1970: 3))
        let dangling = conversation(
            title: "Dangling",
            cwd: destination.cwd,
            projectID: UUID(),
            updatedAt: Date(timeIntervalSince1970: 4))
        ProjectStore.shared.upsert(destination)
        ProjectStore.shared.upsert(foreign)
        [local, foreignStale, dangling].forEach(ConversationStore.shared.upsert)
        let previousLastLocation = UserDefaults.standard.string(forKey: lastLocationKey)
        let settings = FileManager.default.temporaryDirectory
            .appendingPathComponent("enter-settings-\(UUID().uuidString)", isDirectory: true)
        let bridge = AgentBridge(settingsBaseOverride: settings, environmentOverride: [:])
        defer {
            bridge.currentID = nil
            bridge.shutdown()
            [local, foreignStale, dangling].forEach {
                ConversationStore.shared.remove($0.id, permanently: true)
            }
            ProjectStore.shared.remove(destination.id)
            ProjectStore.shared.remove(foreign.id)
            ConversationStore.shared.flushSaves()
            ProjectStore.shared.flushSaves()
            if let previousLastLocation {
                UserDefaults.standard.set(previousLastLocation, forKey: lastLocationKey)
            } else {
                UserDefaults.standard.removeObject(forKey: lastLocationKey)
            }
            try? FileManager.default.removeItem(at: settings)
        }

        bridge.enterWorkspace(destination)

        XCTAssertEqual(bridge.currentID, local.id)
        XCTAssertEqual(bridge.cwd, destination.cwd)
        XCTAssertEqual(ConversationStore.shared.conversation(local.id)?.cwd, destination.cwd)
    }

    func testNewConversationDoesNotRecreateAnUnresolvedRemovedWorkspace() {
        let removed = Project(
            name: "Removed",
            cwd: "/private/tmp/removed-new-conversation-\(UUID().uuidString)")
        ProjectStore.shared.upsert(removed)
        let settings = FileManager.default.temporaryDirectory
            .appendingPathComponent("removed-new-settings-\(UUID().uuidString)", isDirectory: true)
        let bridge = AgentBridge(settingsBaseOverride: settings, environmentOverride: [:])
        bridge.cwd = removed.cwd
        bridge.projectID = nil
        ProjectStore.shared.remove(removed.id)
        defer {
            bridge.currentID = nil
            bridge.shutdown()
            ProjectStore.shared.remove(removed.id)
            ProjectStore.shared.flushSaves()
            try? FileManager.default.removeItem(at: settings)
        }

        bridge.newConversation()

        XCTAssertNil(bridge.currentID)
        XCTAssertFalse(ProjectStore.shared.projects.contains(where: { $0.cwd == removed.cwd }))
    }

    func testNewConversationInheritsTheCurrentWorkspaceConversationProviderAndModel() {
        let workspace = Project(
            name: "Inherited model",
            cwd: "/private/tmp/inherited-model-\(UUID().uuidString)")
        let selection = ModelSelection(
            access: .claudeSubscription,
            modelID: "claude-opus-4-8")
        let source = Conversation(
            title: "Current",
            cwd: workspace.cwd,
            sdkSessionId: nil,
            modelSelection: selection,
            messages: [],
            updatedAt: Date(),
            projectID: workspace.id)

        XCTAssertEqual(
            AgentBridge.currentWorkspaceNewConversationSelection(
                source: source,
                destinationScope: .project(workspace.id),
                projectedSelection: ModelSelection(
                    access: .codexSubscription,
                    modelID: "gpt-5.2-codex"),
                projects: [workspace]),
            selection,
            "An explicit New Conversation keeps the provider and model of the conversation it follows, not a global Codex fallback.")
    }

    func testNewConversationUsesTheProjectedSelectionForALegacyCurrentConversation() {
        let workspace = Project(
            name: "Legacy inherited model",
            cwd: "/private/tmp/legacy-inherited-model-\(UUID().uuidString)")
        let projected = ModelSelection(access: .openAIAPI, modelID: "gpt-5")
        let legacy = Conversation(
            title: "Current legacy",
            cwd: workspace.cwd,
            sdkSessionId: nil,
            messages: [],
            updatedAt: Date(),
            projectID: workspace.id)

        XCTAssertEqual(
            AgentBridge.currentWorkspaceNewConversationSelection(
                source: legacy,
                destinationScope: .project(workspace.id),
                projectedSelection: projected,
                projects: [workspace]),
            projected,
            "An old row without a model stamp still follows the model the current window uses.")
    }

    func testNewConversationDoesNotImportAModelFromAnotherWorkspace() {
        let sourceWorkspace = Project(
            name: "Source model workspace",
            cwd: "/private/tmp/source-model-workspace-\(UUID().uuidString)")
        let destinationWorkspace = Project(
            name: "Destination model workspace",
            cwd: "/private/tmp/destination-model-workspace-\(UUID().uuidString)")
        let source = Conversation(
            title: "Current elsewhere",
            cwd: sourceWorkspace.cwd,
            sdkSessionId: nil,
            modelSelection: ModelSelection(access: .claudeSubscription, modelID: "claude-opus-4-8"),
            messages: [],
            updatedAt: Date(),
            projectID: sourceWorkspace.id)

        XCTAssertNil(
            AgentBridge.currentWorkspaceNewConversationSelection(
                source: source,
                destinationScope: .project(destinationWorkspace.id),
                projectedSelection: ModelSelection(access: .openAIAPI, modelID: "gpt-5"),
                projects: [sourceWorkspace, destinationWorkspace]),
            "Opening an empty different Workspace must continue to use that Workspace's own default.")
    }

    func testForksRetainHomeTopicAndFolderWorkspaceMetadata() {
        let fallback = ModelSelection(access: .claudeSubscription, modelID: "fallback")
        let chosen = ModelSelection(access: .openAIAPI, modelID: "chosen")
        let topicID = UUID()
        let folderID = UUID()
        let topic = Project(id: topicID, name: "Topic")
        let folder = Project(id: folderID, name: "Folder", cwd: "/private/tmp/folder-fork")
        let projects = [topic, folder]
        let sources = [
            conversation(title: "Home", cwd: "", projectID: nil),
            conversation(title: "Topic", cwd: "/stale-topic", projectID: topicID),
            Conversation(
                title: "Folder",
                cwd: "/stale-folder",
                sdkSessionId: "old-session",
                modelSelection: chosen,
                messages: [],
                updatedAt: Date(),
                projectID: folderID),
        ]

        for source in sources {
            let retained = [TranscriptEntry(kind: .user, text: "Retained context")]
            let forkPointEntryID = UUID()
            let forkedAt = Date(timeIntervalSince1970: 1_786_223_400)
            let fork = AgentBridge.forkedConversation(
                from: source,
                id: UUID(),
                messages: retained,
                fallbackModelSelection: fallback,
                projects: projects,
                forkPointEntryID: forkPointEntryID,
                forkedAt: forkedAt)

            XCTAssertEqual(fork.projectID, source.projectID)
            let expectedCwd = WorkspaceScope.resolve(conversation: source, projects: projects)
                .flatMap { $0.canonicalBinding(projects: projects)?.cwd }
                ?? source.cwd
            XCTAssertEqual(fork.cwd, expectedCwd)
            XCTAssertEqual(fork.messages.map(\.id), retained.map(\.id))
            XCTAssertNil(fork.sdkSessionId)
            XCTAssertEqual(fork.modelSelection, source.modelSelection ?? fallback)
            XCTAssertEqual(fork.forkProvenance?.sourceConversationID, source.id)
            XCTAssertEqual(fork.forkProvenance?.sourceTitleSnapshot, source.displayTitle)
            XCTAssertEqual(fork.forkProvenance?.forkPointEntryID, forkPointEntryID)
            XCTAssertEqual(fork.forkProvenance?.createdAt, forkedAt)
        }
    }

    private func conversation(
        title: String,
        cwd: String,
        projectID: UUID?,
        message: String? = nil,
        updatedAt: Date = Date()
    ) -> Conversation {
        Conversation(
            title: title,
            cwd: cwd,
            sdkSessionId: nil,
            messages: message.map { [TranscriptEntry(kind: .user, text: $0)] } ?? [],
            updatedAt: updatedAt,
            projectID: projectID)
    }

    // MARK: - Relevance

    private func project() -> Project { Project(name: "Local", cwd: "/private/tmp/local") }

    private func hit(_ id: UUID, _ score: Double, _ excerpt: String?)
    -> ConversationProjectionStore.SearchHit {
        ConversationProjectionStore.SearchHit(id: id, score: score, excerpt: excerpt)
    }

    /// Search results used to keep pin-and-recency order, because the index answered an unordered
    /// `Set`. A conversation that mentions a term once could outrank the one that is about it,
    /// purely for being newer.
    func testSearchResultsFollowRelevanceRatherThanRecency() {
        let project = project()
        let passing = conversation(
            title: "Older", cwd: project.cwd, projectID: project.id, message: "needle once",
            updatedAt: Date(timeIntervalSince1970: 1_000))
        let about = conversation(
            title: "Newer", cwd: project.cwd, projectID: project.id, message: "needle needle",
            updatedAt: Date(timeIntervalSince1970: 2_000))
        // Handed over in canonical order, newest first, which is exactly what shipped today. The
        // assertion below is that relevance overturns it rather than merely agreeing with it.
        let ordered = [about, passing].map(ConversationSummary.init)

        let relevance = ConversationSearchRelevance(hits: [
            hit(passing.id, -3.0, nil), hit(about.id, -1.0, nil),
        ])
        let snapshot = ConversationSidebarSnapshot.make(
            orderedConversations: ordered,
            scope: .project(project.id),
            projects: [project],
            query: "needle",
            contentMatches: [passing.id, about.id],
            relevance: relevance)

        XCTAssertEqual(snapshot.visibleConversations.map(\.id), [passing.id, about.id],
                       "the better-scoring conversation must lead, whatever its recency")
    }

    /// A title match is the most direct answer to what was typed, and the index cannot score it:
    /// only content is indexed, so a title-only hit has no bm25 rank at all.
    func testATitleMatchOutranksAContentMatch() {
        let project = project()
        let byContent = conversation(
            title: "Something else", cwd: project.cwd, projectID: project.id,
            message: "needle in the body")
        let byTitle = conversation(
            title: "Needle", cwd: project.cwd, projectID: project.id, message: "unrelated")
        let ordered = [byContent, byTitle].map(ConversationSummary.init)

        let snapshot = ConversationSidebarSnapshot.make(
            orderedConversations: ordered,
            scope: .project(project.id),
            projects: [project],
            query: "needle",
            contentMatches: [byContent.id],
            relevance: ConversationSearchRelevance(hits: [hit(byContent.id, -9.0, nil)]))

        XCTAssertEqual(snapshot.visibleConversations.first?.id, byTitle.id)
    }

    /// The row should say why it is in the list. Its ordinary snippet is the newest message, which
    /// can have nothing to do with a match found in tool output weeks earlier.
    func testTheRowShowsTheTextThatMatched() {
        let project = project()
        let c = conversation(
            title: "Notarize", cwd: project.cwd, projectID: project.id,
            message: "the most recent message, about something else")
        let snapshot = ConversationSidebarSnapshot.make(
            orderedConversations: [ConversationSummary(c)],
            scope: .project(project.id),
            projects: [project],
            query: "ticket",
            contentMatches: [c.id],
            relevance: ConversationSearchRelevance(
                hits: [hit(c.id, -2.0, "…notarization ticket 7F2A accepted…")]))

        XCTAssertEqual(snapshot.visibleConversations.first?.snippet,
                       "…notarization ticket 7F2A accepted…")
    }

    /// No excerpt is a normal outcome, not an error: the match can sit past the fetched window.
    func testAMissingExcerptLeavesTheOrdinarySnippetAlone() {
        let project = project()
        let c = conversation(
            title: "Notarize", cwd: project.cwd, projectID: project.id, message: "recent message")
        let original = ConversationSummary(c).snippet
        let snapshot = ConversationSidebarSnapshot.make(
            orderedConversations: [ConversationSummary(c)],
            scope: .project(project.id),
            projects: [project],
            query: "ticket",
            contentMatches: [c.id],
            relevance: ConversationSearchRelevance(hits: [hit(c.id, -2.0, nil)]))

        XCTAssertEqual(snapshot.visibleConversations.first?.snippet, original)
    }

    /// Without an index answer the list must behave exactly as it did before.
    func testWithoutRelevanceTheOrderIsUnchanged() {
        let project = project()
        let a = conversation(
            title: "Needle A", cwd: project.cwd, projectID: project.id, message: "x")
        let b = conversation(
            title: "Needle B", cwd: project.cwd, projectID: project.id, message: "x")
        let ordered = [a, b].map(ConversationSummary.init)
        let snapshot = ConversationSidebarSnapshot.make(
            orderedConversations: ordered,
            scope: .project(project.id),
            projects: [project],
            query: "needle")
        XCTAssertEqual(snapshot.visibleConversations.map(\.id), [a.id, b.id])
    }
}
