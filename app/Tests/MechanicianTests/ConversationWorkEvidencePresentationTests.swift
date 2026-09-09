import XCTest
@testable import Mechanician

final class ConversationWorkEvidencePresentationTests: XCTestCase {
    private let repositoryID = "/repo/.git"
    private let worktree = "/repo/topic"
    private let headOID = String(repeating: "a", count: 40)

    func testGroupsExactTurnEdgesAndRetainsTranscriptAndFileReceipts() throws {
        let conversationID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
        let promptID = UUID(uuidString: "10000000-0000-0000-0000-000000000002")!
        let finalID = UUID(uuidString: "10000000-0000-0000-0000-000000000003")!
        let fileID = UUID(uuidString: "10000000-0000-0000-0000-000000000004")!
        let turnID = "turn-release"
        let startedAt = Date(timeIntervalSince1970: 100)
        let editedAt = Date(timeIntervalSince1970: 110)
        let completedAt = Date(timeIntervalSince1970: 120)

        let started = observation(
            id: UUID(uuidString: "10000000-0000-0000-0000-000000000010")!,
            conversationID: conversationID,
            turnID: turnID,
            reason: .turnStarted,
            rootPrompt: (promptID, "Add exact release evidence.", false),
            observedAt: startedAt)
        let tool = observation(
            id: UUID(uuidString: "10000000-0000-0000-0000-000000000011")!,
            conversationID: conversationID,
            turnID: turnID,
            toolUseID: "tool-write",
            reason: .toolCompleted,
            observedAt: editedAt,
            attribution: .directTool)
        let completed = observation(
            id: UUID(uuidString: "10000000-0000-0000-0000-000000000012")!,
            conversationID: conversationID,
            turnID: turnID,
            reason: .turnCompleted,
            rootPromptID: promptID,
            finalAssistant: (finalID, "Implemented it and ran the focused tests.", true),
            observedAt: completedAt,
            indexChanges: 1,
            worktreeChanges: 2,
            untracked: 1)
        let receipt = file(
            id: fileID,
            repositoryObservationID: tool.id,
            conversationID: conversationID,
            turnID: turnID,
            toolUseID: "tool-write",
            path: "app/Sources/ReleaseEvidence.swift",
            operation: .write,
            beforeDigest: nil,
            afterDigest: String(repeating: "b", count: 64),
            beforeExists: false,
            afterExists: true,
            patch: "+struct ReleaseEvidence {}",
            patchWasTruncated: true,
            observedAt: editedAt)
        let checkedAt = Date(timeIntervalSince1970: 130)
        let git = availableGit(checkedAt: checkedAt)

        let result = ConversationWorkEvidencePresentation.make(
            records: [
                ConversationWorkEvidence(repository: completed, files: []),
                ConversationWorkEvidence(repository: tool, files: [receipt]),
                ConversationWorkEvidence(repository: started, files: []),
            ],
            currentGit: git,
            targetRef: nil)

        XCTAssertEqual(result.checkedAt, checkedAt)
        let conversation = try XCTUnwrap(result.conversations.only)
        XCTAssertEqual(conversation.conversationID, conversationID)
        XCTAssertEqual(conversation.checkedAt, completedAt)
        XCTAssertEqual(conversation.repository?.indexChangeCount, 1)
        XCTAssertEqual(conversation.repository?.worktreeChangeCount, 2)
        XCTAssertEqual(conversation.repository?.untrackedCount, 1)

        let work = try XCTUnwrap(conversation.work.only)
        XCTAssertEqual(work.turnID, turnID)
        XCTAssertEqual(work.capturedAt, completedAt)
        XCTAssertEqual(work.personAsked, ChangesTranscriptEvidence(
            entryID: promptID,
            text: "Add exact release evidence.",
            capturedAt: startedAt,
            truncated: false))
        XCTAssertEqual(work.agentReported, ChangesTranscriptEvidence(
            entryID: finalID,
            text: "Implemented it and ran the focused tests.",
            capturedAt: completedAt,
            truncated: true))

        let presentedFile = try XCTUnwrap(work.observedFiles.only)
        XCTAssertEqual(presentedFile.id, fileID.uuidString.lowercased())
        XCTAssertEqual(presentedFile.path, "/repo/topic/app/Sources/ReleaseEvidence.swift")
        XCTAssertEqual(presentedFile.operation, .created)
        XCTAssertEqual(presentedFile.provenance, .directFileTool(toolUseID: "tool-write"))
        XCTAssertEqual(presentedFile.afterDigest, String(repeating: "b", count: 64))
        XCTAssertEqual(presentedFile.patch, "+struct ReleaseEvidence {}")
        XCTAssertTrue(presentedFile.patchWasTruncated)
        XCTAssertEqual(presentedFile.repositoryState, .noCurrentDiff)
    }

    func testCurrentFileStateUsesOnlyExactWorktreeGitAndCommitProof() throws {
        let conversationID = UUID(uuidString: "20000000-0000-0000-0000-000000000001")!
        let observationID = UUID(uuidString: "20000000-0000-0000-0000-000000000002")!
        let observedAt = Date(timeIntervalSince1970: 200)
        let observation = self.observation(
            id: observationID,
            conversationID: conversationID,
            turnID: "turn-files",
            toolUseID: "tool-edit",
            reason: .toolCompleted,
            observedAt: observedAt,
            attribution: .directTool)
        let modified = file(
            id: UUID(uuidString: "20000000-0000-0000-0000-000000000003")!,
            repositoryObservationID: observationID,
            conversationID: conversationID,
            turnID: "turn-files",
            toolUseID: "tool-edit",
            path: "Sources/Modified.swift",
            operation: .edit,
            beforeExists: true,
            afterExists: true,
            observedAt: observedAt)
        let committedDigest = String(repeating: "a", count: 64)
        let committed = file(
            id: UUID(uuidString: "20000000-0000-0000-0000-000000000004")!,
            repositoryObservationID: observationID,
            conversationID: conversationID,
            turnID: "turn-files",
            toolUseID: "tool-edit",
            path: "Sources/Committed.swift",
            operation: .edit,
            afterDigest: committedDigest,
            beforeExists: true,
            afterExists: true,
            observedAt: observedAt)
        let commitOID = String(repeating: "c", count: 40)
        var git = availableGit(checkedAt: Date(timeIntervalSince1970: 210))
        git.files = [GitFile(
            path: "Sources/Modified.swift",
            originalPath: nil,
            x: "M",
            y: "M",
            staged: true,
            untracked: false)]
        git.activityCommitOIDs["/repo/topic/Sources/Committed.swift"] = commitOID
        git.activityCommitDigests["/repo/topic/Sources/Committed.swift"] = committedDigest
        git.repositoryEvidence.commitReachability = [GitCommitReachability(
            oid: commitOID,
            resolvedOID: commitOID,
            state: .available,
            localBranchRefs: ["refs/heads/main", "refs/heads/dev"])]

        let result = ConversationWorkEvidencePresentation.make(
            records: [ConversationWorkEvidence(
                repository: observation,
                files: [committed, modified])],
            currentGit: git,
            targetRef: nil)
        let files = try XCTUnwrap(result.conversations.only?.work.only?.observedFiles)
        let byName = Dictionary(uniqueKeysWithValues: files.map { ($0.name, $0) })

        XCTAssertEqual(
            byName["Modified.swift"]?.repositoryState,
            .uncommitted(indexStatus: "Modified", worktreeStatus: "Modified"))
        XCTAssertEqual(
            byName["Committed.swift"]?.repositoryState,
            .committed(
                commitOID: commitOID,
                reachableFrom: ["refs/heads/dev", "refs/heads/main"]))

        var digestMismatchGit = git
        digestMismatchGit.activityCommitDigests["/repo/topic/Sources/Committed.swift"] =
            String(repeating: "b", count: 64)
        let mismatchResult = ConversationWorkEvidencePresentation.make(
            records: [ConversationWorkEvidence(repository: observation, files: [committed])],
            currentGit: digestMismatchGit,
            targetRef: nil)
        XCTAssertEqual(
            mismatchResult.conversations.only?.work.only?.observedFiles.only?.repositoryState,
            .noCurrentDiff)

        var otherWorktreeGit = git
        otherWorktreeGit.repositoryEvidence.worktreeRoot = "/repo/integration"
        otherWorktreeGit.repoRoot = "/repo/integration"
        let otherResult = ConversationWorkEvidencePresentation.make(
            records: [ConversationWorkEvidence(repository: observation, files: [modified])],
            currentGit: otherWorktreeGit,
            targetRef: nil)
        XCTAssertEqual(
            otherResult.conversations.only?.work.only?.observedFiles.only?.repositoryState,
            nil)
    }

    func testMapsExactTargetContainmentAndCurrentBranchReachability() throws {
        let includedConversation = UUID(uuidString: "30000000-0000-0000-0000-000000000001")!
        let excludedConversation = UUID(uuidString: "30000000-0000-0000-0000-000000000002")!
        let includedOID = String(repeating: "d", count: 40)
        let excludedOID = String(repeating: "e", count: 40)
        let targetOID = String(repeating: "f", count: 40)
        let targetRef = "refs/heads/main"
        let included = observation(
            conversationID: includedConversation,
            turnID: "turn-included",
            reason: .changesRefresh,
            headOID: includedOID,
            symbolicRef: "refs/heads/dev",
            observedAt: Date(timeIntervalSince1970: 300))
        let excluded = observation(
            conversationID: excludedConversation,
            turnID: "turn-excluded",
            reason: .changesRefresh,
            headOID: excludedOID,
            symbolicRef: "refs/heads/topic",
            observedAt: Date(timeIntervalSince1970: 301))
        var git = availableGit(checkedAt: Date(timeIntervalSince1970: 310))
        git.repositoryEvidence.head = GitHeadEvidence(
            state: .attached,
            oid: targetOID,
            symbolicRef: targetRef,
            upstreamRef: nil,
            upstreamOID: nil,
            ahead: nil,
            behind: nil)
        git.repositoryEvidence.localBranchesState = .available
        git.repositoryEvidence.localBranches = [GitLocalBranchEvidence(
            ref: targetRef,
            name: "main",
            tipOID: targetOID)]
        git.repositoryEvidence.commitReachability = [
            GitCommitReachability(
                oid: includedOID,
                resolvedOID: includedOID,
                state: .available,
                localBranchRefs: [targetRef, "refs/heads/dev"],
                targetRelationship: .ancestor),
            GitCommitReachability(
                oid: excludedOID,
                resolvedOID: excludedOID,
                state: .available,
                localBranchRefs: ["refs/heads/topic"],
                targetRelationship: .notAncestor),
        ]
        git.repositoryEvidence.frozenTarget = GitFrozenTargetEvidence(
            requestedOID: targetOID,
            resolvedOID: targetOID,
            relationship: .equal,
            ahead: 0,
            behind: 0)

        let result = ConversationWorkEvidencePresentation.make(
            records: [
                ConversationWorkEvidence(repository: excluded, files: []),
                ConversationWorkEvidence(repository: included, files: []),
            ],
            currentGit: git,
            targetRef: targetRef)
        let byConversation = Dictionary(uniqueKeysWithValues: result.conversations.map {
            ($0.conversationID, $0)
        })

        XCTAssertEqual(
            byConversation[includedConversation]?.repository?.relationship,
            .includedInTarget(targetCommitsAfterSource: nil))
        XCTAssertEqual(
            byConversation[includedConversation]?.repository?.headReachability,
            .available(localBranchRefs: ["refs/heads/dev", targetRef]))
        XCTAssertEqual(
            byConversation[excludedConversation]?.repository?.relationship,
            .notIncludedInTarget)
        XCTAssertEqual(
            byConversation[excludedConversation]?.repository?.headReachability,
            .available(localBranchRefs: ["refs/heads/topic"]))
        XCTAssertEqual(byConversation[includedConversation]?.repository?.targetOID, targetOID)
        XCTAssertEqual(byConversation[includedConversation]?.repository?.targetRef, targetRef)
    }

    func testMapsFrozenCurrentHeadRelationshipWithoutTopologyInference() throws {
        let sourceOID = String(repeating: "1", count: 40)
        let targetOID = String(repeating: "2", count: 40)
        let conversationID = UUID(uuidString: "40000000-0000-0000-0000-000000000001")!
        let observation = self.observation(
            conversationID: conversationID,
            turnID: "turn-ahead",
            reason: .changesRefresh,
            headOID: sourceOID,
            symbolicRef: "refs/heads/release",
            observedAt: Date(timeIntervalSince1970: 400))
        var git = availableGit(checkedAt: Date(timeIntervalSince1970: 410))
        git.repositoryEvidence.head = GitHeadEvidence(
            state: .attached,
            oid: sourceOID,
            symbolicRef: "refs/heads/release",
            upstreamRef: nil,
            upstreamOID: nil,
            ahead: nil,
            behind: nil)
        git.repositoryEvidence.frozenTarget = GitFrozenTargetEvidence(
            requestedOID: targetOID,
            resolvedOID: targetOID,
            relationship: .headAhead,
            ahead: 2,
            behind: 0)
        git.repositoryEvidence.localBranchesState = .available
        git.repositoryEvidence.localBranches = [GitLocalBranchEvidence(
            ref: "refs/heads/main",
            name: "main",
            tipOID: targetOID)]

        let result = ConversationWorkEvidencePresentation.make(
            records: [ConversationWorkEvidence(repository: observation, files: [])],
            currentGit: git,
            targetRef: "refs/heads/main")

        XCTAssertEqual(
            result.conversations.only?.repository?.relationship,
            .sourceAheadOfTarget(commits: 2))
        XCTAssertEqual(result.conversations.only?.repository?.targetOID, targetOID)
    }

    func testOneTurnKeepsFilesWithTheBranchSnapshotWhereEachWasObserved() throws {
        let conversationID = UUID(uuidString: "45000000-0000-0000-0000-000000000001")!
        let promptID = UUID(uuidString: "45000000-0000-0000-0000-000000000002")!
        let reportID = UUID(uuidString: "45000000-0000-0000-0000-000000000003")!
        let firstID = UUID(uuidString: "45000000-0000-0000-0000-000000000004")!
        let secondID = UUID(uuidString: "45000000-0000-0000-0000-000000000005")!
        let first = observation(
            id: firstID,
            conversationID: conversationID,
            turnID: "turn-branches",
            toolUseID: "tool-first",
            reason: .toolCompleted,
            rootPrompt: (promptID, "Update both implementations", false),
            headOID: String(repeating: "6", count: 40),
            symbolicRef: "refs/heads/dev",
            observedAt: Date(timeIntervalSince1970: 450),
            attribution: .directTool)
        let second = observation(
            id: secondID,
            conversationID: conversationID,
            turnID: "turn-branches",
            toolUseID: "tool-second",
            reason: .toolCompleted,
            finalAssistant: (reportID, "Updated both branches", false),
            headOID: String(repeating: "7", count: 40),
            symbolicRef: "refs/heads/topic",
            observedAt: Date(timeIntervalSince1970: 451),
            attribution: .directTool)
        let firstFile = file(
            id: UUID(), repositoryObservationID: firstID,
            conversationID: conversationID, turnID: "turn-branches",
            toolUseID: "tool-first", path: "Sources/First.swift", operation: .edit,
            beforeExists: true, afterExists: true,
            observedAt: Date(timeIntervalSince1970: 450))
        let secondFile = file(
            id: UUID(), repositoryObservationID: secondID,
            conversationID: conversationID, turnID: "turn-branches",
            toolUseID: "tool-second", path: "Sources/Second.swift", operation: .edit,
            beforeExists: true, afterExists: true,
            observedAt: Date(timeIntervalSince1970: 451))

        let result = ConversationWorkEvidencePresentation.make(
            records: [
                ConversationWorkEvidence(repository: second, files: [secondFile]),
                ConversationWorkEvidence(repository: first, files: [firstFile]),
            ],
            currentGit: availableGit(checkedAt: Date(timeIntervalSince1970: 460)),
            targetRef: nil)
        let work = try XCTUnwrap(result.conversations.only?.work)
        XCTAssertEqual(work.count, 2)
        let byFile = Dictionary(uniqueKeysWithValues: work.compactMap { item in
            item.observedFiles.only.map { ($0.name, item) }
        })
        XCTAssertEqual(byFile["First.swift"]?.repository?.symbolicRef, "refs/heads/dev")
        XCTAssertEqual(byFile["Second.swift"]?.repository?.symbolicRef, "refs/heads/topic")
        XCTAssertEqual(byFile["First.swift"]?.personAsked?.entryID, promptID)
        XCTAssertEqual(byFile["Second.swift"]?.agentReported?.entryID, reportID)
    }

    func testRequiresCanonicalRepositoryIdentityAndFiltersForeignRecords() throws {
        let local = observation(
            conversationID: UUID(uuidString: "50000000-0000-0000-0000-000000000001")!,
            turnID: "turn-local",
            reason: .changesRefresh,
            observedAt: Date(timeIntervalSince1970: 500))
        var foreign = observation(
            conversationID: UUID(uuidString: "50000000-0000-0000-0000-000000000002")!,
            turnID: "turn-foreign",
            reason: .changesRefresh,
            observedAt: Date(timeIntervalSince1970: 501))
        foreign = ConversationRepositoryObservation(
            id: foreign.id,
            conversationID: foreign.conversationID,
            turnID: foreign.turnID,
            toolUseID: foreign.toolUseID,
            reason: foreign.reason,
            rootPromptEntryID: foreign.rootPromptEntryID,
            finalAssistantEntryID: foreign.finalAssistantEntryID,
            rootPromptExcerpt: foreign.rootPromptExcerpt,
            rootPromptExcerptWasTruncated: foreign.rootPromptExcerptWasTruncated,
            finalAssistantExcerpt: foreign.finalAssistantExcerpt,
            finalAssistantExcerptWasTruncated: foreign.finalAssistantExcerptWasTruncated,
            repositoryID: "/other/.git",
            gitCommonDirectory: "/other/.git",
            worktreePath: "/other/topic",
            workspaceID: foreign.workspaceID,
            canonicalCWD: "/other/topic",
            headState: foreign.headState,
            symbolicRef: foreign.symbolicRef,
            headOID: foreign.headOID,
            statusAvailability: foreign.statusAvailability,
            indexChangeCount: foreign.indexChangeCount,
            worktreeChangeCount: foreign.worktreeChangeCount,
            untrackedCount: foreign.untrackedCount,
            attribution: foreign.attribution,
            observedAt: foreign.observedAt)
        let git = availableGit(checkedAt: Date(timeIntervalSince1970: 510))

        let result = ConversationWorkEvidencePresentation.make(
            records: [
                ConversationWorkEvidence(repository: foreign, files: []),
                ConversationWorkEvidence(repository: local, files: []),
            ],
            currentGit: git,
            targetRef: nil)
        XCTAssertEqual(result.conversations.map(\.conversationID), [local.conversationID])

        var unavailableGit = git
        unavailableGit.repositoryEvidence.state = .unavailable
        XCTAssertTrue(ConversationWorkEvidencePresentation.make(
            records: [ConversationWorkEvidence(repository: local, files: [])],
            currentGit: unavailableGit,
            targetRef: nil).conversations.isEmpty)
    }

    private func availableGit(checkedAt: Date) -> GitStatus {
        var git = GitStatus(
            probe: .repository,
            workspaceCwd: worktree,
            repoRoot: worktree)
        var repository = GitRepositoryEvidence()
        repository.state = .available
        repository.checkedAt = checkedAt
        repository.worktreeRoot = worktree
        repository.gitCommonDir = repositoryID
        repository.head = GitHeadEvidence(
            state: .attached,
            oid: headOID,
            symbolicRef: "refs/heads/topic",
            upstreamRef: nil,
            upstreamOID: nil,
            ahead: nil,
            behind: nil)
        git.repositoryEvidence = repository
        return git
    }

    private func observation(
        id: UUID = UUID(),
        conversationID: UUID,
        turnID: String,
        toolUseID: String? = nil,
        reason: ConversationRepositoryObservationReason,
        rootPromptID: UUID? = nil,
        rootPrompt: (UUID, String, Bool)? = nil,
        finalAssistant: (UUID, String, Bool)? = nil,
        headOID: String? = nil,
        symbolicRef: String? = "refs/heads/topic",
        observedAt: Date,
        attribution: ConversationWorkAttribution? = nil,
        indexChanges: Int = 0,
        worktreeChanges: Int = 0,
        untracked: Int = 0
    ) -> ConversationRepositoryObservation {
        ConversationRepositoryObservation(
            id: id,
            conversationID: conversationID,
            turnID: turnID,
            toolUseID: toolUseID,
            reason: reason,
            rootPromptEntryID: rootPrompt?.0 ?? rootPromptID,
            finalAssistantEntryID: finalAssistant?.0,
            rootPromptExcerpt: rootPrompt?.1,
            rootPromptExcerptWasTruncated: rootPrompt?.2,
            finalAssistantExcerpt: finalAssistant?.1,
            finalAssistantExcerptWasTruncated: finalAssistant?.2,
            repositoryID: repositoryID,
            gitCommonDirectory: repositoryID,
            worktreePath: worktree,
            workspaceID: nil,
            canonicalCWD: worktree,
            headState: .attached,
            symbolicRef: symbolicRef,
            headOID: headOID ?? self.headOID,
            statusAvailability: .available,
            indexChangeCount: indexChanges,
            worktreeChangeCount: worktreeChanges,
            untrackedCount: untracked,
            attribution: attribution,
            observedAt: observedAt)
    }

    private func file(
        id: UUID,
        repositoryObservationID: UUID,
        conversationID: UUID,
        turnID: String,
        toolUseID: String,
        path: String,
        operation: ConversationFileOperation,
        beforeDigest: String? = nil,
        afterDigest: String? = nil,
        beforeExists: Bool?,
        afterExists: Bool?,
        patch: String? = nil,
        patchWasTruncated: Bool = false,
        observedAt: Date
    ) -> ConversationFileObservation {
        ConversationFileObservation(
            id: id,
            repositoryObservationID: repositoryObservationID,
            conversationID: conversationID,
            turnID: turnID,
            toolUseID: toolUseID,
            repositoryID: repositoryID,
            repositoryRelativePath: path,
            operation: operation,
            attribution: .directTool,
            beforeDigest: beforeDigest,
            afterDigest: afterDigest,
            beforeExists: beforeExists,
            afterExists: afterExists,
            boundedPatch: patch,
            patchWasTruncated: patchWasTruncated,
            observedAt: observedAt)
    }
}

private extension Array {
    var only: Element? { count == 1 ? first : nil }
}
