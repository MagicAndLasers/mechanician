import Foundation

/// Pure, exact-edge adapter from durable Conversation work receipts to the immutable Changes
/// inspector input. The current Git probe supplies the repository join key and current checkout
/// facts; titles remain the responsibility of `ChangesInspectorPresentation`.
enum ConversationWorkEvidencePresentation {
    private struct TurnKey: Hashable {
        let conversationID: UUID
        let turnID: String
    }

    /// A turn may cross branches or worktrees. File receipts remain grouped only while every
    /// source-location fact is identical; the Conversation/turn edge alone is not a Git location.
    private struct WorkSourceKey: Hashable {
        let repositoryID: String
        let worktreePath: String
        let headState: String?
        let symbolicRef: String?
        let headOID: String?
    }

    /// Build the Conversation-first evidence for the repository proven by `currentGit`.
    ///
    /// `targetRef` is an explicit full ref selected by the caller. It is never defaulted to `main`,
    /// the current branch, or any similarly likely target. When the Git probe does not provide a
    /// canonical common-directory identity, the adapter returns no Conversation rows rather than
    /// joining records by working directory, title, branch label, or time.
    static func make(
        records: [ConversationWorkEvidence],
        currentGit: GitStatus,
        targetRef: String?
    ) -> ChangesInspectorEvidence {
        let currentRepository = currentGit.repositoryEvidence
        guard let repositoryID = currentRepository.repositoryIdentity else {
            return ChangesInspectorEvidence(
                conversations: [],
                checkedAt: currentRepository.checkedAt)
        }

        let scopedRecords = records.filter {
            $0.repository.repositoryID == repositoryID
                && $0.repository.gitCommonDirectory == repositoryID
        }
        let selectedTargetRef = validFullRef(targetRef)
        let recordsByConversation = Dictionary(
            grouping: scopedRecords,
            by: { $0.repository.conversationID })

        let conversations = recordsByConversation.map { conversationID, conversationRecords in
            let recordsByTurn = Dictionary(
                grouping: conversationRecords,
                by: {
                    TurnKey(
                        conversationID: conversationID,
                        turnID: $0.repository.turnID)
                })
            let work = recordsByTurn.flatMap { turnKey, turnRecords -> [ChangesWorkEvidence] in
                let observations = turnRecords.map(\.repository)
                    .sorted(by: repositoryObservationNewestFirst)
                let personAsked = observations.compactMap(rootPromptEvidence).first
                let agentReported = observations.compactMap(finalAssistantEvidence).first
                let recordsBySource = Dictionary(grouping: turnRecords) { record in
                    WorkSourceKey(
                        repositoryID: record.repository.repositoryID,
                        worktreePath: record.repository.worktreePath,
                        headState: record.repository.headState?.rawValue,
                        symbolicRef: record.repository.symbolicRef,
                        headOID: record.repository.headOID)
                }
                return recordsBySource.map { sourceKey, sourceRecords in
                    let sourceIdentity = [
                        sourceKey.repositoryID,
                        sourceKey.worktreePath,
                        sourceKey.headState ?? "",
                        sourceKey.symbolicRef ?? "",
                        sourceKey.headOID ?? "",
                    ].joined(separator: "\u{0}")
                    return workEvidence(
                        id: turnKey.conversationID.uuidString.lowercased()
                            + ":" + turnKey.turnID + ":" + sourceIdentity,
                        records: sourceRecords,
                        personAsked: personAsked,
                        agentReported: agentReported,
                        currentGit: currentGit,
                        targetRef: selectedTargetRef)
                }
            }.sorted(by: workSort)
            let latestRepository = conversationRecords
                .map(\.repository)
                .max(by: repositoryObservationSort)
            let repository = latestRepository.map {
                repositoryEvidence(
                    from: $0,
                    currentGit: currentGit,
                    targetRef: selectedTargetRef)
            }
            let checkedAt = conversationRecords.map(\.repository.observedAt).max()
            return ChangesConversationEvidence(
                conversationID: conversationID,
                work: work,
                repository: repository,
                checkedAt: checkedAt)
        }.sorted {
            let left = $0.checkedAt ?? .distantPast
            let right = $1.checkedAt ?? .distantPast
            if left != right { return left > right }
            return $0.conversationID.uuidString < $1.conversationID.uuidString
        }

        return ChangesInspectorEvidence(
            conversations: conversations,
            checkedAt: currentRepository.checkedAt)
    }

    private static func workEvidence(
        id: String,
        records: [ConversationWorkEvidence],
        personAsked: ChangesTranscriptEvidence?,
        agentReported: ChangesTranscriptEvidence?,
        currentGit: GitStatus,
        targetRef: String?
    ) -> ChangesWorkEvidence {
        let observations = records.map(\.repository).sorted(by: repositoryObservationNewestFirst)
        let latestRepository = observations.first

        var fileByID: [UUID: ChangesObservedFileEvidence] = [:]
        for record in records.sorted(by: workRecordSort) {
            for file in record.files.sorted(by: fileObservationSort) {
                guard fileByID[file.id] == nil else { continue }
                fileByID[file.id] = observedFileEvidence(
                    file,
                    repository: record.repository,
                    currentGit: currentGit)
            }
        }
        let files = fileByID.values.sorted(by: observedFileSort)
        let capturedAt = (
            observations.map(\.observedAt) + records.flatMap(\.files).map(\.observedAt)
        ).max() ?? .distantPast

        return ChangesWorkEvidence(
            id: id,
            turnID: observations.first?.turnID,
            personAsked: personAsked,
            agentReported: agentReported,
            observedFiles: files,
            repository: latestRepository.map {
                repositoryEvidence(
                    from: $0,
                    currentGit: currentGit,
                    targetRef: targetRef)
            },
            capturedAt: capturedAt)
    }

    private static func rootPromptEvidence(
        _ observation: ConversationRepositoryObservation
    ) -> ChangesTranscriptEvidence? {
        guard let entryID = observation.rootPromptEntryID,
              let text = observation.rootPromptExcerpt,
              let truncated = observation.rootPromptExcerptWasTruncated else { return nil }
        return ChangesTranscriptEvidence(
            entryID: entryID,
            text: text,
            capturedAt: observation.observedAt,
            truncated: truncated)
    }

    private static func finalAssistantEvidence(
        _ observation: ConversationRepositoryObservation
    ) -> ChangesTranscriptEvidence? {
        guard let entryID = observation.finalAssistantEntryID,
              let text = observation.finalAssistantExcerpt,
              let truncated = observation.finalAssistantExcerptWasTruncated else { return nil }
        return ChangesTranscriptEvidence(
            entryID: entryID,
            text: text,
            capturedAt: observation.observedAt,
            truncated: truncated)
    }

    private static func observedFileEvidence(
        _ file: ConversationFileObservation,
        repository: ConversationRepositoryObservation,
        currentGit: GitStatus
    ) -> ChangesObservedFileEvidence {
        let absolutePath = (repository.worktreePath as NSString)
            .appendingPathComponent(file.repositoryRelativePath)
        let operation = observedOperation(file)
        let provenance: ChangesEvidenceProvenance
        switch file.attribution {
        case .directTool:
            provenance = .directFileTool(toolUseID: file.toolUseID)
        case .observedDuringTool:
            provenance = .observedDuringConversation(toolUseID: file.toolUseID)
        }
        return ChangesObservedFileEvidence(
            id: file.id.uuidString.lowercased(),
            path: absolutePath,
            operation: operation,
            provenance: provenance,
            capturedAt: file.observedAt,
            beforeDigest: file.beforeDigest,
            afterDigest: file.afterDigest,
            patch: file.boundedPatch,
            patchWasTruncated: file.patchWasTruncated,
            repositoryState: currentRepositoryState(
                for: file,
                operation: operation,
                repository: repository,
                absolutePath: absolutePath,
                currentGit: currentGit))
    }

    private static func observedOperation(
        _ file: ConversationFileObservation
    ) -> ChangesObservedFileOperation {
        if file.operation == .read { return .read }
        if file.beforeExists == false, file.afterExists == true { return .created }
        if file.beforeExists == true, file.afterExists == false { return .deleted }
        return .edited
    }

    /// Dirty bytes are scoped to one exact worktree. A different linked worktree may share refs,
    /// but its index and working tree cannot describe this receipt's current file state.
    private static func currentRepositoryState(
        for file: ConversationFileObservation,
        operation: ChangesObservedFileOperation,
        repository: ConversationRepositoryObservation,
        absolutePath: String,
        currentGit: GitStatus
    ) -> ChangesFileRepositoryState? {
        guard operation.isMutation else { return nil }
        guard currentGit.repositoryEvidence.worktreeRoot == repository.worktreePath else {
            return nil
        }
        guard currentGit.probe == .repository,
              currentGit.repositoryEvidence.repositoryIdentity == repository.repositoryID else {
            return currentGit.probe == .unavailable ? .unavailable : nil
        }

        if let gitFile = currentGit.files.first(where: {
            $0.operationPaths.contains(file.repositoryRelativePath)
        }) {
            let indexStatus = gitFile.hasStagedChange
                ? gitFile.statusName(stagedSide: true) : nil
            let worktreeStatus = gitFile.hasUnstagedChange
                ? gitFile.statusName(stagedSide: false) : nil
            return .uncommitted(
                indexStatus: indexStatus,
                worktreeStatus: worktreeStatus)
        }

        let standardizedPath = (absolutePath as NSString).standardizingPath
        let commitPair = currentGit.activityCommitOIDs.first { path, _ in
            (path as NSString).standardizingPath == standardizedPath
        }
        let verifiedDigest = currentGit.activityCommitDigests.first { path, _ in
            (path as NSString).standardizingPath == standardizedPath
        }?.value
        if let commit = commitPair?.value,
           let capturedDigest = file.afterDigest,
           verifiedDigest == capturedDigest {
            let refs = exactReachability(for: commit, in: currentGit.repositoryEvidence)
            if case .available(let localBranchRefs) = refs {
                return .committed(commitOID: commit, reachableFrom: localBranchRefs)
            }
            return .committed(commitOID: commit, reachableFrom: [])
        }
        return .noCurrentDiff
    }

    private static func repositoryEvidence(
        from observation: ConversationRepositoryObservation,
        currentGit: GitStatus,
        targetRef: String?
    ) -> ChangesRepositoryEvidence {
        let gitEvidence = currentGit.repositoryEvidence
        let targetOID = exactTargetOID(for: targetRef, in: gitEvidence)
        let reachability = observation.headOID.map {
            exactReachability(for: $0, in: gitEvidence)
        } ?? .notChecked
        return ChangesRepositoryEvidence(
            repositoryID: observation.repositoryID,
            commonDirectory: observation.gitCommonDirectory,
            worktreePath: observation.worktreePath,
            symbolicRef: observation.symbolicRef,
            headOID: observation.headOID,
            targetRef: targetRef,
            targetOID: targetOID,
            relationship: targetRelationship(
                sourceOID: observation.headOID,
                targetRef: targetRef,
                targetOID: targetOID,
                reachability: reachability,
                git: gitEvidence),
            headReachability: reachability,
            indexChangeCount: observation.indexChangeCount,
            worktreeChangeCount: observation.worktreeChangeCount,
            untrackedCount: observation.untrackedCount,
            checkedAt: observation.observedAt)
    }

    private static func exactReachability(
        for oid: String,
        in git: GitRepositoryEvidence
    ) -> ChangesCommitReachability {
        guard let evidence = git.commitReachability.first(where: { $0.oid == oid }) else {
            return .notChecked
        }
        switch evidence.state {
        case .available:
            return .available(localBranchRefs: Array(Set(evidence.localBranchRefs)).sorted())
        case .missing:
            return .commitMissing
        case .unavailable:
            return .unavailable
        }
    }

    private static func targetRelationship(
        sourceOID: String?,
        targetRef: String?,
        targetOID: String?,
        reachability: ChangesCommitReachability,
        git: GitRepositoryEvidence
    ) -> ChangesRepositoryRelationship {
        guard let sourceOID, let targetOID else { return .unknown }
        if sourceOID == targetOID { return .sameCommit }

        // A caller may explicitly freeze a target other than the visible checkout (for example,
        // main while reviewing a dev checkout). These graph counts are safe only when both sides
        // still name the exact immutable objects from this one Git result.
        if sourceOID == git.head.oid,
           let frozenTarget = git.frozenTarget,
           (frozenTarget.resolvedOID ?? frozenTarget.requestedOID) == targetOID {
            switch frozenTarget.relationship {
            case .equal:
                return .sameCommit
            case .headAhead:
                guard let ahead = frozenTarget.ahead else { return .unknown }
                return .sourceAheadOfTarget(commits: ahead)
            case .headBehind:
                guard let behind = frozenTarget.behind else { return .unknown }
                return .includedInTarget(targetCommitsAfterSource: behind)
            case .diverged:
                guard let ahead = frozenTarget.ahead,
                      let behind = frozenTarget.behind else { return .unknown }
                return .diverged(sourceOnly: ahead, targetOnly: behind)
            case .missing, .unavailable:
                return .unknown
            }
        }

        guard targetRefPointsAt(targetRef, targetOID: targetOID, in: git),
              let evidence = git.commitReachability.first(where: {
                  $0.oid == sourceOID && ($0.resolvedOID ?? $0.oid) == sourceOID
              }) else { return .unknown }
        switch evidence.targetRelationship {
        case .equal:
            return .sameCommit
        case .ancestor:
            return .includedInTarget(targetCommitsAfterSource: nil)
        case .notAncestor:
            return .notIncludedInTarget
        case .missing, .unavailable:
            return .unknown
        }
    }

    private static func validFullRef(_ value: String?) -> String? {
        guard let value, value.hasPrefix("refs/") else { return nil }
        return value
    }

    /// Resolve only an explicitly named local target. HEAD and the local-ref census are two exact
    /// observations from the same Git result; neither requires guessing which branch is a release
    /// target. A frozen target can describe topology only after its OID matches this resolution.
    private static func exactTargetOID(
        for targetRef: String?,
        in git: GitRepositoryEvidence
    ) -> String? {
        guard let targetRef else { return nil }
        if git.head.state == .attached,
           git.head.symbolicRef == targetRef,
           let oid = git.head.oid {
            return oid
        }
        guard git.localBranchesState == .available else { return nil }
        return git.localBranches.first(where: { $0.ref == targetRef })?.tipOID
    }

    private static func targetRefPointsAt(
        _ targetRef: String?,
        targetOID: String,
        in git: GitRepositoryEvidence
    ) -> Bool {
        guard let targetRef else { return false }
        return git.head.state == .attached
            && git.head.symbolicRef == targetRef
            && git.head.oid == targetOID
    }

    private static func repositoryObservationSort(
        _ left: ConversationRepositoryObservation,
        _ right: ConversationRepositoryObservation
    ) -> Bool {
        if left.observedAt != right.observedAt { return left.observedAt < right.observedAt }
        return left.id.uuidString < right.id.uuidString
    }

    private static func repositoryObservationNewestFirst(
        _ left: ConversationRepositoryObservation,
        _ right: ConversationRepositoryObservation
    ) -> Bool {
        if left.observedAt != right.observedAt { return left.observedAt > right.observedAt }
        return left.id.uuidString < right.id.uuidString
    }

    private static func workRecordSort(
        _ left: ConversationWorkEvidence,
        _ right: ConversationWorkEvidence
    ) -> Bool {
        repositoryObservationNewestFirst(left.repository, right.repository)
    }

    private static func fileObservationSort(
        _ left: ConversationFileObservation,
        _ right: ConversationFileObservation
    ) -> Bool {
        if left.observedAt != right.observedAt { return left.observedAt > right.observedAt }
        if left.repositoryRelativePath != right.repositoryRelativePath {
            return left.repositoryRelativePath < right.repositoryRelativePath
        }
        return left.id.uuidString < right.id.uuidString
    }

    private static func observedFileSort(
        _ left: ChangesObservedFileEvidence,
        _ right: ChangesObservedFileEvidence
    ) -> Bool {
        if left.capturedAt != right.capturedAt { return left.capturedAt > right.capturedAt }
        if left.path != right.path { return left.path < right.path }
        return left.id < right.id
    }

    private static func workSort(
        _ left: ChangesWorkEvidence,
        _ right: ChangesWorkEvidence
    ) -> Bool {
        if left.capturedAt != right.capturedAt { return left.capturedAt > right.capturedAt }
        return left.id < right.id
    }
}
