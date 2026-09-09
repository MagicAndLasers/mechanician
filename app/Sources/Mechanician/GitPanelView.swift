import SwiftUI

// Git model types shared by AgentBridge (the `git`/`gitDiff` state) and ChangesPanelView.
// Git state and agent activity intentionally remain separate: Git describes the workspace now;
// activity describes what Mechanician observed during this conversation.

enum GitProbeState {
    case idle
    case checking
    case repository
    case notRepository
    case unavailable
}

struct GitFile: Identifiable {
    var id: String { [originalPath, path].compactMap { $0 }.joined(separator: "→") }
    let path: String
    let originalPath: String?
    let x: String
    let y: String
    let staged: Bool
    let untracked: Bool

    var operationPaths: [String] {
        originalPath.map { [$0, path] } ?? [path]
    }

    var displayPath: String {
        originalPath.map { "\($0) → \(path)" } ?? path
    }

    var hasStagedChange: Bool { x != " " && x != "?" }
    var hasUnstagedChange: Bool { untracked || y != " " }

    var statusLabel: String {
        if untracked { return "?" }
        return staged ? x : y
    }

    func statusCode(stagedSide: Bool) -> String {
        if untracked { return "?" }
        return stagedSide ? x : y
    }

    func statusName(stagedSide: Bool) -> String {
        let code = statusCode(stagedSide: stagedSide)
        if [x, y].contains("U") || ["DD", "AU", "UD", "UA", "DU", "AA"].contains(x + y) {
            return "Conflicted"
        }
        switch code {
        case "M": return "Modified"
        case "A": return "Added"
        case "D": return "Deleted"
        case "R": return "Renamed"
        case "C": return "Copied"
        case "T": return "Type changed"
        case "?": return "Untracked"
        default: return "Changed"
        }
    }
}

enum GitRepositoryEvidenceState: String, Equatable {
    case notCaptured = "not_captured"
    case available
    case gitCLIUnavailable = "git_cli_unavailable"
    case unavailable
    case notRepository = "not_repository"
}

enum GitEvidenceCensusState: String, Equatable {
    case notCaptured = "not_captured"
    case available
    case unavailable
}

enum GitHeadState: String, Equatable {
    case attached
    case detached
    case unborn
    case unavailable
}

struct GitHeadEvidence: Equatable {
    var state: GitHeadState = .unavailable
    var oid: String?
    /// The full ref (`refs/heads/...`), never the friendly branch label.
    var symbolicRef: String?
    var upstreamRef: String?
    var upstreamOID: String?
    var ahead: Int?
    var behind: Int?
}

struct GitLocalBranchEvidence: Equatable {
    let ref: String
    let name: String
    let tipOID: String
}

enum GitCommitReachabilityState: String, Equatable {
    case available
    case missing
    case unavailable
}

/// Exact relationship of a requested commit to the checkout HEAD OID captured by the same probe.
/// `ancestor` means that the candidate is an ancestor of, and therefore included in, that HEAD.
enum GitCommitTargetRelationship: String, Equatable {
    case equal
    case ancestor
    case notAncestor
    case missing
    case unavailable
}

struct GitCommitReachability: Equatable {
    let oid: String
    let resolvedOID: String?
    /// Availability of the independent local-branch containment census.
    let state: GitCommitReachabilityState
    let localBranchRefs: [String]
    let targetRelationship: GitCommitTargetRelationship

    init(
        oid: String,
        resolvedOID: String?,
        state: GitCommitReachabilityState,
        localBranchRefs: [String],
        targetRelationship: GitCommitTargetRelationship = .unavailable
    ) {
        self.oid = oid
        self.resolvedOID = resolvedOID
        self.state = state
        self.localBranchRefs = localBranchRefs
        self.targetRelationship = targetRelationship
    }
}

enum GitFrozenTargetRelationship: String, Equatable {
    case equal
    case headAhead
    case headBehind
    case diverged
    case missing
    case unavailable
}

struct GitFrozenTargetEvidence: Equatable {
    let requestedOID: String
    let resolvedOID: String?
    let relationship: GitFrozenTargetRelationship
    let ahead: Int?
    let behind: Int?
}

enum GitRegisteredWorktreeState: String, Equatable {
    case attached
    case detached
    case unborn
    case bare
    case unavailable
}

struct GitRegisteredWorktreeEvidence: Equatable {
    let path: String
    let state: GitRegisteredWorktreeState
    let headOID: String?
    let symbolicRef: String?
    let locked: Bool
    let prunable: Bool
}

/// Exact repository facts captured alongside a status response.
///
/// These deliberately do not wrap `GitFile`: dirty bytes belong to a worktree and index, while a
/// symbolic ref describes HEAD. Keeping the facts separate prevents the UI from claiming that an
/// uncommitted edit is "on" whichever branch HEAD happened to name when this probe ran.
struct GitRepositoryEvidence: Equatable {
    var state: GitRepositoryEvidenceState = .notCaptured
    var checkedAt: Date?
    var worktreeRoot: String?
    var gitCommonDir: String?
    var unavailableReason: String?
    var head = GitHeadEvidence()
    var localBranchesState: GitEvidenceCensusState = .notCaptured
    var localBranches: [GitLocalBranchEvidence] = []
    var registeredWorktreesState: GitEvidenceCensusState = .notCaptured
    var registeredWorktrees: [GitRegisteredWorktreeEvidence] = []
    var commitReachability: [GitCommitReachability] = []
    var frozenTarget: GitFrozenTargetEvidence?

    /// The canonical common directory is the exact join key shared by linked worktrees.
    var repositoryIdentity: String? {
        state == .available ? gitCommonDir : nil
    }

    func localBranchRefs(containing oid: String) -> [String]? {
        guard let evidence = commitReachability.first(where: {
            $0.oid == oid || $0.resolvedOID == oid
        }), evidence.state == .available else { return nil }
        return evidence.localBranchRefs
    }

    init() {}

    init(wireValue: Any?) {
        guard let value = wireValue as? [String: Any] else { return }
        state = (value["state"] as? String).flatMap(GitRepositoryEvidenceState.init(rawValue:))
            ?? .unavailable
        if let seconds = Self.number(value["checkedAt"]) {
            checkedAt = Date(timeIntervalSince1970: seconds)
        }
        worktreeRoot = Self.nonemptyString(value["worktreeRoot"])
        gitCommonDir = Self.nonemptyString(value["gitCommonDir"])
        unavailableReason = Self.nonemptyString(value["unavailableReason"])

        if let rawHead = value["head"] as? [String: Any] {
            let rawState = (rawHead["state"] as? String).flatMap(GitHeadState.init(rawValue:))
                ?? .unavailable
            let oid = Self.fullOID(rawHead["oid"])
            let symbolicRef = Self.fullLocalBranchRef(rawHead["symbolicRef"])
            let state: GitHeadState
            switch rawState {
            case .attached where oid != nil && symbolicRef != nil: state = .attached
            case .detached where oid != nil: state = .detached
            case .unborn where symbolicRef != nil: state = .unborn
            case .unavailable: state = .unavailable
            default: state = .unavailable
            }
            head = GitHeadEvidence(
                state: state,
                oid: state == .attached || state == .detached ? oid : nil,
                symbolicRef: state == .attached || state == .unborn ? symbolicRef : nil,
                upstreamRef: state == .attached ? Self.fullRef(rawHead["upstreamRef"]) : nil,
                upstreamOID: state == .attached ? Self.fullOID(rawHead["upstreamOID"]) : nil,
                ahead: state == .attached ? Self.integer(rawHead["ahead"]) : nil,
                behind: state == .attached ? Self.integer(rawHead["behind"]) : nil)
        }

        localBranchesState = (value["localBranchesState"] as? String)
            .flatMap(GitEvidenceCensusState.init(rawValue:)) ?? .unavailable
        if let branches = value["localBranches"] as? [[String: Any]] {
            localBranches = branches.compactMap { branch in
                guard let ref = Self.fullLocalBranchRef(branch["ref"]),
                      let name = Self.nonemptyString(branch["name"]),
                      name == String(ref.dropFirst("refs/heads/".count)),
                      let tipOID = Self.fullOID(branch["tipOID"]) else { return nil }
                return GitLocalBranchEvidence(ref: ref, name: name, tipOID: tipOID)
            }
        }

        registeredWorktreesState = (value["registeredWorktreesState"] as? String)
            .flatMap(GitEvidenceCensusState.init(rawValue:)) ?? .unavailable
        if let worktrees = value["registeredWorktrees"] as? [[String: Any]] {
            registeredWorktrees = worktrees.compactMap { worktree in
                guard let path = Self.nonemptyString(worktree["path"]),
                      let rawState = worktree["state"] as? String,
                      let state = GitRegisteredWorktreeState(rawValue: rawState) else { return nil }
                let headOID = Self.fullOID(worktree["headOID"])
                let symbolicRef = Self.fullLocalBranchRef(worktree["symbolicRef"])
                guard (state != .attached || (headOID != nil && symbolicRef != nil)),
                      (state != .detached || headOID != nil),
                      (state != .unborn || symbolicRef != nil) else { return nil }
                return GitRegisteredWorktreeEvidence(
                    path: path,
                    state: state,
                    headOID: state == .unborn ? nil : headOID,
                    symbolicRef: state == .attached || state == .unborn ? symbolicRef : nil,
                    locked: worktree["locked"] as? Bool ?? false,
                    prunable: worktree["prunable"] as? Bool ?? false)
            }
        }

        if let reachability = value["commitReachability"] as? [[String: Any]] {
            commitReachability = reachability.compactMap { item in
                guard let oid = Self.fullOID(item["oid"]),
                      let rawState = item["state"] as? String,
                      let state = GitCommitReachabilityState(rawValue: rawState) else { return nil }
                let resolvedOID = Self.fullOID(item["resolvedOID"])
                let refs = (item["localBranchRefs"] as? [String] ?? [])
                    .compactMap { Self.fullLocalBranchRef($0) }
                return GitCommitReachability(
                    oid: oid,
                    resolvedOID: resolvedOID,
                    state: state,
                    localBranchRefs: refs,
                    targetRelationship: Self.commitTargetRelationship(
                        item["targetRelationship"],
                        candidateState: state,
                        resolvedOID: resolvedOID,
                        capturedHeadOID: head.oid))
            }
        }

        if let target = value["frozenTarget"] as? [String: Any],
           let requestedOID = Self.fullOID(target["requestedOID"]),
           let rawRelationship = target["relationship"] as? String,
           let relationship = GitFrozenTargetRelationship(rawValue: rawRelationship) {
            frozenTarget = GitFrozenTargetEvidence(
                requestedOID: requestedOID,
                resolvedOID: Self.fullOID(target["resolvedOID"]),
                relationship: relationship,
                ahead: Self.integer(target["ahead"]),
                behind: Self.integer(target["behind"]))
        }
    }

    private static func nonemptyString(_ value: Any?) -> String? {
        guard let value = value as? String, !value.isEmpty else { return nil }
        return value
    }

    private static func fullRef(_ value: Any?) -> String? {
        guard let value = nonemptyString(value), value.hasPrefix("refs/") else { return nil }
        return value
    }

    private static func fullLocalBranchRef(_ value: Any?) -> String? {
        guard let value = nonemptyString(value), value.hasPrefix("refs/heads/") else { return nil }
        return value
    }

    private static func fullOID(_ value: Any?) -> String? {
        guard let value = nonemptyString(value)?.lowercased(), [40, 64].contains(value.count),
              value.allSatisfy({ $0.isHexDigit }), value.contains(where: { $0 != "0" })
        else { return nil }
        return value
    }

    private static func number(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }

    private static func integer(_ value: Any?) -> Int? {
        (value as? NSNumber)?.intValue
    }

    private static func commitTargetRelationship(
        _ value: Any?,
        candidateState: GitCommitReachabilityState,
        resolvedOID: String?,
        capturedHeadOID: String?
    ) -> GitCommitTargetRelationship {
        guard let rawValue = value as? String,
              let relationship = GitCommitTargetRelationship(rawValue: rawValue) else {
            return .unavailable
        }
        switch relationship {
        case .equal:
            return resolvedOID != nil && resolvedOID == capturedHeadOID ? .equal : .unavailable
        case .ancestor, .notAncestor:
            guard resolvedOID != nil, capturedHeadOID != nil,
                  resolvedOID != capturedHeadOID else { return .unavailable }
            return relationship
        case .missing:
            return candidateState == .missing && resolvedOID == nil ? .missing : .unavailable
        case .unavailable:
            return .unavailable
        }
    }
}

struct GitStatus {
    var probe: GitProbeState = .idle
    var workspaceCwd = ""
    var branch = ""
    var ahead = 0
    var behind = 0
    var repoRoot = ""     // absolute repo toplevel; porcelain paths are relative to it
    var files: [GitFile] = []
    /// Git-history evidence for clean Agent Activity rows, keyed by absolute path.
    var activityCommits: [String: String] = [:]
    /// Full immutable commit IDs for durable evidence capture. The abbreviated map above remains
    /// the existing presentation API.
    var activityCommitOIDs: [String: String] = [:]
    /// SHA-256 of the exact file bytes that the daemon verified before attributing a path commit.
    var activityCommitDigests: [String: String] = [:]
    var repositoryEvidence = GitRepositoryEvidence()
    var isRepo: Bool { probe == .repository }
    var stagedFiles: [GitFile] { files.filter(\.hasStagedChange) }
    var unstagedFiles: [GitFile] { files.filter(\.hasUnstagedChange) }

    /// What a commit from this panel is claiming the index contains.
    ///
    /// The daemon commits the whole index rather than a pathspec, because `git commit -- <paths>`
    /// commits working-tree contents and ignores what was staged. In a checkout shared by several
    /// conversations the index can hold files this panel never listed, so the commit declares this
    /// set and the daemon refuses instead of committing someone else's staged work. Renames
    /// contribute both sides, since which one `git diff --cached` reports depends on rename
    /// detection.
    var commitExpectationPaths: [String] {
        stagedFiles.flatMap(\.operationPaths).sorted()
    }

    func belongs(to cwd: String) -> Bool {
        workspaceCwd == cwd && [.repository, .notRepository, .unavailable].contains(probe)
    }

    /// Absolute path of a porcelain (repo-root-relative) git file, for correlating with the
    /// agent's touched-file list (which uses absolute paths).
    func absolutePath(_ gitPath: String) -> String {
        repoRoot.isEmpty ? gitPath : (repoRoot as NSString).appendingPathComponent(gitPath)
    }
}

struct GitDiff: Identifiable {
    let id = UUID()
    let path: String
    let text: String
}
