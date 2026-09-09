import XCTest
@testable import Mechanician

final class ChangesPanelTests: XCTestCase {
    private func summary(
        id: UUID,
        title: String,
        updatedAt: Date
    ) -> ConversationSummary {
        ConversationSummary(
            id: id,
            title: title,
            workspaceCWD: "/workspace",
            workspaceID: nil,
            updatedAt: updatedAt,
            messageCount: 2,
            snippet: "Done",
            hasUserMessage: true,
            favorite: false,
            sortIndex: nil,
            unread: false,
            errored: false,
            awaitingQuestion: false,
            hasRunningDelegate: false,
            providerAccessName: nil,
            armedWaitSummary: nil)
    }

    /// The read-only preview drew the whole file as one `Text`, which past a few thousand points of
    /// height renders nothing at all — previewing AgentBridge.swift or agentd.mjs showed an empty
    /// pane. Rendering per line fixes that, and the row count has to stay bounded so an enormous
    /// file cannot realize an unbounded number of rows.
    func testPreviewSplitsIntoBoundedLines() {
        XCTAssertEqual(ChangesPanelView.previewLines("one\ntwo\nthree"), ["one", "two", "three"])
        XCTAssertEqual(ChangesPanelView.previewLines(""), [""])

        let long = (1...200).map(String.init).joined(separator: "\n")
        let clipped = ChangesPanelView.previewLines(long, maxLines: 50)
        XCTAssertEqual(clipped.count, 52)
        XCTAssertEqual(clipped.first, "1")
        XCTAssertEqual(clipped[49], "50")
        XCTAssertEqual(clipped.last, "… preview truncated …")
    }

    func testPreviewReadsOnlyItsBoundedPrefix() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChangesPanelTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("large.txt")
        try Data(repeating: 0x61, count: 160_001).write(to: file)

        let preview = ChangesPanelView.previewText(for: file.path)

        XCTAssertTrue(preview.hasSuffix("\n\n… preview truncated …"))
        XCTAssertEqual(preview.prefix(160_000).count, 160_000)
    }

    func testConversationDisclosureDefaultsAndChevronToggle() {
        let currentID = UUID()
        let otherID = UUID()
        var disclosure = ChangesConversationDisclosureState()

        XCTAssertTrue(disclosure.isExpanded(conversationID: currentID, isCurrent: true))
        disclosure.toggle(conversationID: currentID, isCurrent: true)
        XCTAssertFalse(disclosure.isExpanded(conversationID: currentID, isCurrent: true))
        disclosure.toggle(conversationID: currentID, isCurrent: true)
        XCTAssertTrue(disclosure.isExpanded(conversationID: currentID, isCurrent: true))

        XCTAssertFalse(disclosure.isExpanded(conversationID: otherID, isCurrent: false))
        disclosure.toggle(conversationID: otherID, isCurrent: false)
        XCTAssertTrue(disclosure.isExpanded(conversationID: otherID, isCurrent: false))
    }

    func testAgentActivityMatchesCurrentGitRowByExactPath() {
        let modified = GitFile(
            path: "app/Sources/Feature.swift", originalPath: nil,
            x: " ", y: "M", staged: false, untracked: false)
        let git = GitStatus(
            probe: .repository,
            workspaceCwd: "/workspace",
            repoRoot: "/workspace",
            files: [modified])

        XCTAssertEqual(
            matchingGitFile(
                forAbsolute: "/workspace/app/Sources/Feature.swift", in: git)?.id,
            modified.id)
        XCTAssertNil(matchingGitFile(forAbsolute: "/workspace/README.md", in: git))
    }

    func testAgentActivityMatchesEitherSideOfGitRename() {
        let renamed = GitFile(
            path: "Sources/New.swift", originalPath: "Sources/Old.swift",
            x: "R", y: " ", staged: true, untracked: false)
        let git = GitStatus(
            probe: .repository,
            workspaceCwd: "/workspace",
            repoRoot: "/workspace",
            files: [renamed])

        XCTAssertNotNil(matchingGitFile(forAbsolute: "/workspace/Sources/Old.swift", in: git))
        XCTAssertNotNil(matchingGitFile(forAbsolute: "/workspace/Sources/New.swift", in: git))
    }

    func testConversationHistoryUsesCurrentGitAsUncommittedTruth() {
        let modified = GitFile(
            path: "Sources/Feature.swift", originalPath: nil,
            x: " ", y: "M", staged: false, untracked: false)
        let git = GitStatus(
            probe: .repository,
            workspaceCwd: "/workspace",
            repoRoot: "/workspace",
            files: [modified])
        var activity = AgentBridge.TouchedFile(path: "/workspace/Sources/Feature.swift")
        activity.edits = 1

        XCTAssertEqual(
            conversationFileOutcome(for: activity, git: git, workspaceCwd: "/workspace"),
            .uncommitted("Modified"))
    }

    func testConversationHistoryClaimsCommitOnlyFromExactGitEvidence() {
        var git = GitStatus(
            probe: .repository,
            workspaceCwd: "/workspace",
            repoRoot: "/workspace")
        git.activityCommits["/workspace/Sources/Feature.swift"] = "abc1234"
        git.activityCommitDigests["/workspace/Sources/Feature.swift"] = "sha256:exact"
        var activity = AgentBridge.TouchedFile(path: "/workspace/Sources/Feature.swift")
        activity.edits = 1
        activity.postEditDigest = "sha256:exact"

        XCTAssertEqual(
            conversationFileOutcome(for: activity, git: git, workspaceCwd: "/workspace"),
            .committed("abc1234"))
        XCTAssertEqual(
            ConversationFileOutcome.committed("abc1234").gitStatusMarker,
            ConversationHistoryGitStatusMarker(
                glyph: "✓", accessibilityLabel: "Already committed in abc1234"))
    }

    func testConversationHistoryRejectsPathOnlyCommitAttribution() {
        var git = GitStatus(
            probe: .repository,
            workspaceCwd: "/workspace",
            repoRoot: "/workspace")
        git.activityCommits["/workspace/Sources/Feature.swift"] = "abc1234"
        git.activityCommitDigests["/workspace/Sources/Feature.swift"] = "sha256:other"
        var activity = AgentBridge.TouchedFile(path: "/workspace/Sources/Feature.swift")
        activity.edits = 1
        activity.postEditDigest = "sha256:observed"

        XCTAssertEqual(
            conversationFileOutcome(for: activity, git: git, workspaceCwd: "/workspace"),
            .noCurrentDiff)

        activity.postEditDigest = nil
        XCTAssertEqual(
            conversationFileOutcome(for: activity, git: git, workspaceCwd: "/workspace"),
            .noCurrentDiff)
    }

    func testConversationHistoryDoesNotInferCommitFromCleanWorktree() {
        let git = GitStatus(
            probe: .repository,
            workspaceCwd: "/workspace",
            repoRoot: "/workspace")
        var edited = AgentBridge.TouchedFile(path: "/workspace/Sources/Feature.swift")
        edited.edits = 1
        var read = AgentBridge.TouchedFile(path: "/workspace/README.md")
        read.reads = 1

        XCTAssertEqual(
            conversationFileOutcome(for: edited, git: git, workspaceCwd: "/workspace"),
            .noCurrentDiff)
        XCTAssertEqual(
            ConversationFileOutcome.noCurrentDiff.gitStatusMarker,
            ConversationHistoryGitStatusMarker(
                glyph: "?",
                accessibilityLabel: "No current Git change; commit or revert not determined"))
        XCTAssertEqual(
            conversationFileOutcome(for: read, git: git, workspaceCwd: "/workspace"),
            .readOnly)
        XCTAssertNil(ConversationFileOutcome.readOnly.gitStatusMarker)
    }

    func testConversationHistoryExplainsNonGitAndOutsideRepositoryPaths() {
        var activity = AgentBridge.TouchedFile(path: "/workspace/Feature.swift")
        activity.edits = 1
        let nonGit = GitStatus(probe: .notRepository, workspaceCwd: "/workspace")

        XCTAssertEqual(
            conversationFileOutcome(for: activity, git: nonGit, workspaceCwd: "/workspace"),
            .notVersionControlled)

        let repository = GitStatus(
            probe: .repository,
            workspaceCwd: "/workspace",
            repoRoot: "/workspace/repo")
        XCTAssertEqual(
            conversationFileOutcome(for: activity, git: repository, workspaceCwd: "/workspace"),
            .outsideRepository)
    }

    /// The Commit button counts `stagedFiles`, but the daemon commits the whole index. In a
    /// checkout shared by several conversations those two sets can differ, and the difference was
    /// committed silently under this conversation's message. The commit now declares what it was
    /// shown so the daemon can refuse; this pins what that declaration contains.
    func testCommitExpectationCoversExactlyTheStagedRows() {
        let staged = GitFile(
            path: "app/Sources/Mine.swift", originalPath: nil,
            x: "M", y: " ", staged: true, untracked: false)
        let unstagedOnly = GitFile(
            path: "app/Sources/Untouched.swift", originalPath: nil,
            x: " ", y: "M", staged: false, untracked: false)
        let untracked = GitFile(
            path: "notes.txt", originalPath: nil,
            x: "?", y: "?", staged: false, untracked: true)
        let git = GitStatus(
            probe: .repository, workspaceCwd: "/workspace", repoRoot: "/workspace",
            files: [staged, unstagedOnly, untracked])

        XCTAssertEqual(git.commitExpectationPaths, ["app/Sources/Mine.swift"])
    }

    /// Whether `git diff --cached --name-only` reports a rename as one path or two depends on
    /// rename detection. Declaring both sides means the guard cannot refuse a legitimate rename
    /// commit either way.
    func testCommitExpectationCarriesBothSidesOfARename() {
        let renamed = GitFile(
            path: "Sources/New.swift", originalPath: "Sources/Old.swift",
            x: "R", y: " ", staged: true, untracked: false)
        let git = GitStatus(
            probe: .repository, workspaceCwd: "/workspace", repoRoot: "/workspace",
            files: [renamed])

        XCTAssertEqual(git.commitExpectationPaths, ["Sources/New.swift", "Sources/Old.swift"])
    }

    /// An empty index declares an empty set rather than no opinion. The daemon treats a missing
    /// declaration as "old app, keep the previous behaviour", so the two must not be confused.
    func testCommitExpectationIsEmptyRatherThanAbsentWhenNothingIsStaged() {
        let git = GitStatus(
            probe: .repository, workspaceCwd: "/workspace", repoRoot: "/workspace", files: [])
        XCTAssertEqual(git.commitExpectationPaths, [])
    }

    func testConversationPresentationKeepsCurrentFirstAndUsesExactSavedTitles() {
        let currentID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let recentID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let olderID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
        let base = Date(timeIntervalSince1970: 1_000)
        let currentFile = ChangesObservedFileEvidence(
            id: "tool-current",
            path: "/workspace/app/Current.swift",
            operation: .edited,
            provenance: .directFileTool(toolUseID: "tool-current"),
            capturedAt: base.addingTimeInterval(1))
        let evidence = ChangesInspectorEvidence(
            conversations: [
                ChangesConversationEvidence(
                    conversationID: olderID,
                    work: [ChangesWorkEvidence(id: "older", capturedAt: base)]),
                ChangesConversationEvidence(
                    conversationID: recentID,
                    work: [ChangesWorkEvidence(
                        id: "recent", capturedAt: base.addingTimeInterval(30))]),
                ChangesConversationEvidence(
                    conversationID: currentID,
                    work: [ChangesWorkEvidence(
                        id: "current", observedFiles: [currentFile], capturedAt: base)])
            ],
            checkedAt: base.addingTimeInterval(31))
        let presentation = ChangesInspectorPresentation.make(
            currentConversationID: currentID,
            summaries: [
                summary(id: olderID, title: "Fix storage bootstrap", updatedAt: base),
                summary(id: currentID, title: "Prepare dogfood release", updatedAt: base),
                summary(id: recentID, title: "Improve file selection", updatedAt: base)
            ],
            evidence: evidence)

        XCTAssertEqual(presentation.current?.id, currentID)
        XCTAssertEqual(presentation.current?.title, "Prepare dogfood release")
        XCTAssertEqual(presentation.current?.work.first?.observedFiles.map(\.path),
                       ["/workspace/app/Current.swift"])
        XCTAssertEqual(presentation.others.map(\.id), [recentID, olderID])
        XCTAssertEqual(presentation.others.map(\.title),
                       ["Improve file selection", "Fix storage bootstrap"])
    }

    func testPresentationNeverInventsTitleForOrphanedAuthorityRecord() {
        let knownID = UUID(uuidString: "00000000-0000-0000-0000-000000000010")!
        let orphanedID = UUID(uuidString: "00000000-0000-0000-0000-000000000011")!
        let now = Date(timeIntervalSince1970: 2_000)
        let presentation = ChangesInspectorPresentation.make(
            currentConversationID: knownID,
            summaries: [summary(id: knownID, title: "Review release", updatedAt: now)],
            evidence: ChangesInspectorEvidence(
                conversations: [ChangesConversationEvidence(conversationID: orphanedID)],
                checkedAt: now))

        XCTAssertEqual(presentation.current?.title, "Review release")
        XCTAssertTrue(presentation.current?.work.isEmpty == true)
        XCTAssertTrue(presentation.others.isEmpty)
    }

    func testLiveFallbackAddsOnlyPathsMissingFromDurableEvidence() {
        let conversationID = UUID(uuidString: "00000000-0000-0000-0000-000000000020")!
        let now = Date(timeIntervalSince1970: 3_000)
        let durable = ChangesObservedFileEvidence(
            id: "durable-a", path: "/workspace/A.swift", operation: .edited,
            provenance: .directFileTool(toolUseID: "durable-a"), capturedAt: now)
        let duplicateLive = ChangesObservedFileEvidence(
            id: "live-a", path: "/workspace/A.swift", operation: .edited,
            provenance: .directFileTool(toolUseID: nil), capturedAt: now)
        let uncoveredLive = ChangesObservedFileEvidence(
            id: "live-b", path: "/workspace/B.swift", operation: .read,
            provenance: .directFileTool(toolUseID: nil), capturedAt: now.addingTimeInterval(1))
        let presentation = ChangesInspectorPresentation.make(
            currentConversationID: conversationID,
            summaries: [summary(id: conversationID, title: "Wire evidence", updatedAt: now)],
            evidence: ChangesInspectorEvidence(
                conversations: [ChangesConversationEvidence(
                    conversationID: conversationID,
                    work: [ChangesWorkEvidence(
                        id: "durable", observedFiles: [durable], capturedAt: now)])],
                checkedAt: now),
            liveObservedFiles: [conversationID: [duplicateLive, uncoveredLive]])

        let paths = presentation.current?.work.flatMap(\.observedFiles).map(\.path) ?? []
        XCTAssertEqual(paths.filter { $0 == "/workspace/A.swift" }.count, 1)
        XCTAssertEqual(Set(paths), ["/workspace/A.swift", "/workspace/B.swift"])
    }

    func testNewerLiveEvidenceForSamePathStaysVisibleAheadOfDurableEvidence() {
        let conversationID = UUID(uuidString: "00000000-0000-0000-0000-000000000021")!
        let now = Date(timeIntervalSince1970: 3_100)
        let durable = ChangesObservedFileEvidence(
            id: "durable", path: "/workspace/A.swift", operation: .edited,
            provenance: .directFileTool(toolUseID: "durable"), capturedAt: now)
        let newerLive = ChangesObservedFileEvidence(
            id: "live", path: "/workspace/A.swift", operation: .edited,
            provenance: .directFileTool(toolUseID: nil),
            capturedAt: now.addingTimeInterval(1))

        let presentation = ChangesInspectorPresentation.make(
            currentConversationID: conversationID,
            summaries: [summary(id: conversationID, title: "Keep live evidence", updatedAt: now)],
            evidence: ChangesInspectorEvidence(
                conversations: [ChangesConversationEvidence(
                    conversationID: conversationID,
                    work: [ChangesWorkEvidence(
                        id: "durable", observedFiles: [durable], capturedAt: now)])],
                checkedAt: now),
            liveObservedFiles: [conversationID: [newerLive]])

        XCTAssertEqual(presentation.current?.work.map(\.id), ["session-live-fallback", "durable"])
        XCTAssertEqual(
            presentation.current?.work.flatMap(\.observedFiles).map(\.id),
            ["live", "durable"])
    }

    func testRepositoryPresentationShortensOnlyAtDisplayBoundary() {
        let checked = Date(timeIntervalSince1970: 4_000)
        let repository = ChangesRepositoryEvidence(
            repositoryID: "repo-1",
            commonDirectory: "/workspace/.git",
            worktreePath: "/workspace/feature",
            symbolicRef: "refs/heads/feature/release-inspector",
            headOID: "1234567890abcdef1234567890abcdef12345678",
            targetRef: "refs/heads/main",
            targetOID: "abcdef1234567890abcdef1234567890abcdef12",
            relationship: .sourceAheadOfTarget(commits: 2),
            indexChangeCount: 1,
            worktreeChangeCount: 2,
            untrackedCount: 1,
            checkedAt: checked)

        XCTAssertEqual(repository.headOID, "1234567890abcdef1234567890abcdef12345678")
        XCTAssertEqual(repository.sourceLabel, "feature/release-inspector@12345678")
        XCTAssertEqual(repository.targetLabel, "main@abcdef12")
        XCTAssertEqual(repository.uncommittedCount, 4)
        XCTAssertEqual(
            repository.relationship.label,
            "Source HEAD is 2 commits ahead of current checkout")
        XCTAssertFalse(repository.relationship.isIncluded)
    }

    func testCleanFileEvidenceNeverClaimsCommit() {
        XCTAssertEqual(
            ChangesFileRepositoryState.noCurrentDiff.label,
            "Path has no current diff; commit or revert not determined")
        XCTAssertEqual(
            ChangesFileRepositoryState.uncommitted(
                indexStatus: nil,
                worktreeStatus: "Modified").label,
            "Path currently modified · worktree: Modified")
        XCTAssertEqual(
            ChangesFileRepositoryState.committed(
                commitOID: "1234567890", reachableFrom: ["refs/heads/dev", "refs/heads/main"])
                .label,
            "Commit 12345678 · reachable from dev, main")
    }

    func testIncludedCheckRequiresKnownCleanSourceAndProvenFileWork() {
        let now = Date(timeIntervalSince1970: 4_100)
        let unknownFileState = ChangesRepositoryEvidence(
            worktreePath: "/workspace/topic",
            relationship: .sameCommit,
            checkedAt: now)
        XCTAssertNil(unknownFileState.uncommittedCount)
        XCTAssertFalse(changesRepositoryCanShowIncludedCheck(
            unknownFileState,
            hasUnprovedMutationWork: false))

        let cleanSource = ChangesRepositoryEvidence(
            worktreePath: "/workspace/topic",
            relationship: .sameCommit,
            indexChangeCount: 0,
            worktreeChangeCount: 0,
            untrackedCount: 0,
            checkedAt: now)
        XCTAssertTrue(changesRepositoryCanShowIncludedCheck(
            cleanSource,
            hasUnprovedMutationWork: false))
        XCTAssertFalse(changesRepositoryCanShowIncludedCheck(
            cleanSource,
            hasUnprovedMutationWork: true))

        let dirtySource = ChangesRepositoryEvidence(
            worktreePath: "/workspace/topic",
            relationship: .sameCommit,
            indexChangeCount: 0,
            worktreeChangeCount: 1,
            untrackedCount: 0,
            checkedAt: now)
        XCTAssertFalse(changesRepositoryCanShowIncludedCheck(
            dirtySource,
            hasUnprovedMutationWork: false))
    }

    func testGitRepositoryEvidenceDecodesExactWorktreeHeadAndReachabilityFacts() {
        let headOID = String(repeating: "a", count: 40)
        let targetOID = String(repeating: "b", count: 40)
        let evidence = GitRepositoryEvidence(wireValue: [
            "state": "available",
            "checkedAt": 1_750_000_000.25,
            "worktreeRoot": "/workspace/topic",
            "gitCommonDir": "/workspace/repository/.git",
            "head": [
                "state": "attached",
                "oid": headOID,
                "symbolicRef": "refs/heads/topic",
                "upstreamRef": "refs/remotes/origin/topic",
                "upstreamOID": headOID,
                "ahead": 2,
                "behind": 1,
            ] as [String: Any],
            "localBranchesState": "available",
            "localBranches": [[
                "ref": "refs/heads/topic", "name": "topic", "tipOID": headOID,
            ]],
            "registeredWorktreesState": "available",
            "registeredWorktrees": [[
                "path": "/workspace/topic", "state": "attached", "headOID": headOID,
                "symbolicRef": "refs/heads/topic",
            ]],
            "commitReachability": [[
                "oid": headOID, "resolvedOID": headOID, "state": "available",
                "localBranchRefs": ["refs/heads/main", "refs/heads/topic"],
                "targetRelationship": "equal",
            ]],
            "frozenTarget": [
                "requestedOID": targetOID, "resolvedOID": targetOID,
                "relationship": "diverged", "ahead": 2, "behind": 1,
            ] as [String: Any],
        ] as [String: Any])

        XCTAssertEqual(evidence.state, .available)
        XCTAssertEqual(evidence.checkedAt, Date(timeIntervalSince1970: 1_750_000_000.25))
        XCTAssertEqual(evidence.worktreeRoot, "/workspace/topic")
        XCTAssertEqual(evidence.repositoryIdentity, "/workspace/repository/.git")
        XCTAssertEqual(evidence.head, GitHeadEvidence(
            state: .attached,
            oid: headOID,
            symbolicRef: "refs/heads/topic",
            upstreamRef: "refs/remotes/origin/topic",
            upstreamOID: headOID,
            ahead: 2,
            behind: 1))
        XCTAssertEqual(evidence.localBranches, [
            GitLocalBranchEvidence(ref: "refs/heads/topic", name: "topic", tipOID: headOID),
        ])
        XCTAssertEqual(
            evidence.localBranchRefs(containing: headOID),
            ["refs/heads/main", "refs/heads/topic"])
        XCTAssertEqual(evidence.commitReachability.first?.targetRelationship, .equal)
        XCTAssertEqual(evidence.registeredWorktrees, [
            GitRegisteredWorktreeEvidence(
                path: "/workspace/topic", state: .attached, headOID: headOID,
                symbolicRef: "refs/heads/topic", locked: false, prunable: false),
        ])
        XCTAssertEqual(evidence.frozenTarget, GitFrozenTargetEvidence(
            requestedOID: targetOID,
            resolvedOID: targetOID,
            relationship: .diverged,
            ahead: 2,
            behind: 1))
    }

    func testGitCommitTargetRelationshipDecodesClosedExactProofs() {
        let headOID = String(repeating: "a", count: 40)
        let ancestorOID = String(repeating: "b", count: 40)
        let notAncestorOID = String(repeating: "c", count: 40)
        let missingOID = String(repeating: "d", count: 40)
        let unavailableOID = String(repeating: "e", count: 40)
        let legacyOID = String(repeating: "f", count: 40)
        let unknownOID = String(repeating: "1", count: 40)
        let evidence = GitRepositoryEvidence(wireValue: [
            "state": "available",
            "head": [
                "state": "attached", "oid": headOID, "symbolicRef": "refs/heads/main",
            ],
            "commitReachability": [
                [
                    "oid": headOID, "resolvedOID": headOID, "state": "available",
                    "localBranchRefs": ["refs/heads/main"], "targetRelationship": "equal",
                ],
                [
                    "oid": ancestorOID, "resolvedOID": ancestorOID, "state": "unavailable",
                    "localBranchRefs": [], "targetRelationship": "ancestor",
                ],
                [
                    "oid": notAncestorOID, "resolvedOID": notAncestorOID, "state": "available",
                    "localBranchRefs": ["refs/heads/topic"], "targetRelationship": "notAncestor",
                ],
                [
                    "oid": missingOID, "state": "missing", "localBranchRefs": [],
                    "targetRelationship": "missing",
                ],
                [
                    "oid": unavailableOID, "resolvedOID": unavailableOID, "state": "available",
                    "localBranchRefs": [], "targetRelationship": "unavailable",
                ],
                [
                    "oid": legacyOID, "resolvedOID": legacyOID, "state": "available",
                    "localBranchRefs": [],
                ],
                [
                    "oid": unknownOID, "resolvedOID": unknownOID, "state": "available",
                    "localBranchRefs": [], "targetRelationship": "descendant",
                ],
            ],
        ] as [String: Any])

        XCTAssertEqual(
            evidence.commitReachability.map(\.targetRelationship),
            [.equal, .ancestor, .notAncestor, .missing, .unavailable, .unavailable, .unavailable])
        XCTAssertEqual(evidence.commitReachability[1].state, .unavailable)
        XCTAssertEqual(evidence.commitReachability[1].targetRelationship, .ancestor,
                       "Local-ref census availability must not erase an exact HEAD proof.")
    }

    func testGitRepositoryEvidenceKeepsUnavailableProofAndLegacyAbsenceDistinct() {
        let legacy = GitRepositoryEvidence(wireValue: nil)
        XCTAssertEqual(legacy.state, .notCaptured)
        XCTAssertNil(legacy.repositoryIdentity)

        let fallback = GitRepositoryEvidence(wireValue: [
            "state": "git_cli_unavailable",
            "checkedAt": 1_750_000_000,
            "worktreeRoot": "/workspace",
            "unavailableReason": "git_cli_unavailable",
            "head": ["state": "unavailable"],
            "localBranchesState": "unavailable",
            "localBranches": [],
            "registeredWorktreesState": "unavailable",
            "registeredWorktrees": [],
            "commitReachability": [],
        ] as [String: Any])

        XCTAssertEqual(fallback.state, .gitCLIUnavailable)
        XCTAssertEqual(fallback.unavailableReason, "git_cli_unavailable")
        XCTAssertEqual(fallback.head.state, .unavailable)
        XCTAssertEqual(fallback.localBranchesState, .unavailable)
        XCTAssertNil(fallback.repositoryIdentity)
    }
}

/// Typing re-arms a lapsed warm provider process (issue #38). The policy has to be cheap enough to
/// consult on every keystroke and must not flood the daemon with identical requests.
@MainActor
final class ComposerPrewarmPolicyTests: XCTestCase {
    func testKeystrokeRearmIsThrottledPerConversation() {
        let conversation = UUID()
        let other = UUID()
        let now = Date(timeIntervalSince1970: 1_000_000)

        XCTAssertTrue(AgentBridge.shouldRearmComposerPrewarm(
            lastConversationID: nil, lastPrewarmedAt: nil,
            conversationID: conversation, now: now),
            "Nothing has been armed yet.")

        XCTAssertFalse(AgentBridge.shouldRearmComposerPrewarm(
            lastConversationID: conversation, lastPrewarmedAt: now,
            conversationID: conversation,
            now: now.addingTimeInterval(AgentBridge.composerPrewarmInterval - 1)),
            "Every keystroke inside the window must not re-send.")

        XCTAssertTrue(AgentBridge.shouldRearmComposerPrewarm(
            lastConversationID: conversation, lastPrewarmedAt: now,
            conversationID: conversation,
            now: now.addingTimeInterval(AgentBridge.composerPrewarmInterval)),
            "Past the window the spare may have lapsed.")

        XCTAssertTrue(AgentBridge.shouldRearmComposerPrewarm(
            lastConversationID: conversation, lastPrewarmedAt: now,
            conversationID: other, now: now),
            "A different conversation is a different warm shape.")
    }

    /// Well under the daemon's five-minute idle expiry, or a keystroke after a pause would trust a
    /// spare that has already been closed.
    func testThrottleStaysInsideTheDaemonIdleExpiry() {
        XCTAssertLessThan(AgentBridge.composerPrewarmInterval, 5 * 60)
    }
}
