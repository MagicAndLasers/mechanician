import AppKit
import Foundation

/// Putting a Workspace move back without putting a large Conversation decode on the main actor.
///
/// AppKit decides whether a registration is Undo or Redo only while its callback is executing. An
/// evicted record cannot be decoded in that callback, so each invocation registers an opposite
/// placeholder synchronously, hydrates the complete impact set, then fills the placeholder with the
/// dynamically captured inverse. A failed load runs a stack-only compensation on the next main turn:
/// no placement changes, and the original action is available to retry.
@MainActor
enum WorkspaceMoveUndo {
    struct ArtifactPlacement: Equatable {
        var workspaceID: UUID?
        var cwd: String
        var conversationID: UUID?
        var conversationTitle: String

        init(_ artifact: Artifact) {
            workspaceID = artifact.workspaceID
            cwd = artifact.cwd
            conversationID = artifact.conversationID
            conversationTitle = artifact.conversationTitle
        }

        func apply(to artifact: inout Artifact) {
            artifact.workspaceID = workspaceID
            artifact.cwd = cwd
            artifact.conversationID = conversationID
            artifact.conversationTitle = conversationTitle
        }
    }

    struct ConversationLocation: Equatable, Hashable {
        var projectID: UUID?
        var cwd: String
    }

    /// Only fields changed by Workspace adoption are recorded. In particular, Undo must not replace
    /// a whole Artifact and erase a title, source, favorite, or other work performed after the move.
    struct Placement: Equatable {
        var location: ConversationLocation?
        var artifacts: [UUID: ArtifactPlacement]
        /// Artifact-delete Undo removes an entry outright and must restore membership. Move receipts
        /// are pruned to placement patches before registration and never carry this whole-array seam.
        var completeArtifacts: [Artifact]?
    }

    struct Record {
        private(set) var conversations: [UUID: Placement] = [:]
        private(set) var artifacts: [UUID: ArtifactPlacement] = [:]

        var isEmpty: Bool { conversations.isEmpty && artifacts.isEmpty }
        var conversationIDs: Set<UUID> { Set(conversations.keys) }
        var durableArtifactIDs: Set<UUID> { Set(artifacts.keys) }

        /// First capture wins. Adoption can visit one holder both as a moved Conversation and as an
        /// artifact reference; its earliest placement is the state Undo must restore.
        mutating func capture(_ conversation: Conversation) {
            guard conversations[conversation.id] == nil else { return }
            conversations[conversation.id] = Placement(
                location: ConversationLocation(
                    projectID: conversation.projectID,
                    cwd: conversation.cwd),
                artifacts: Dictionary(conversation.artifacts.map {
                    ($0.uuid, ArtifactPlacement($0))
                }, uniquingKeysWith: { first, _ in first }),
                completeArtifacts: conversation.artifacts)
        }

        /// Artifact deletion needs the old nested membership, but it did not move the containing
        /// Conversation. Leaving location out prevents its Undo from masquerading as a Workspace
        /// move and handing a live Conversation to a different window.
        mutating func captureArtifactMembership(_ conversation: Conversation) {
            guard conversations[conversation.id] == nil else { return }
            conversations[conversation.id] = Placement(
                location: nil,
                artifacts: [:],
                completeArtifacts: conversation.artifacts)
        }

        mutating func capture(artifacts values: [UUID: Artifact]) {
            for (id, artifact) in values where artifacts[id] == nil {
                artifacts[id] = ArtifactPlacement(artifact)
            }
        }

        mutating func setConversationPlacement(_ placement: Placement, for id: UUID) {
            conversations[id] = placement
        }

        mutating func setArtifactPlacement(_ placement: ArtifactPlacement, for id: UUID) {
            artifacts[id] = placement
        }

        /// Capture exactly the fields another record will overwrite. This is the dynamic inverse
        /// filled after hydration, immediately before the resident-only commit.
        mutating func capture(_ conversation: Conversation, matching target: Placement) {
            var placement = conversations[conversation.id] ?? Placement(
                location: nil,
                artifacts: [:],
                completeArtifacts: nil)
            if target.location != nil, placement.location == nil {
                placement.location = ConversationLocation(
                    projectID: conversation.projectID,
                    cwd: conversation.cwd)
            }
            let current = Dictionary(conversation.artifacts.map {
                ($0.uuid, ArtifactPlacement($0))
            }, uniquingKeysWith: { first, _ in first })
            for id in target.artifacts.keys where placement.artifacts[id] == nil {
                if let value = current[id] { placement.artifacts[id] = value }
            }
            if target.completeArtifacts != nil, placement.completeArtifacts == nil {
                placement.completeArtifacts = conversation.artifacts
            }
            conversations[conversation.id] = placement
        }

        /// A same-UUID reference can be added after the forward move. It follows the durable
        /// artifact's placement without moving its containing Conversation between Workspaces.
        mutating func mergeCurrentHolder(
            _ conversation: Conversation,
            durableTargets: [UUID: ArtifactPlacement]
        ) {
            var placement = conversations[conversation.id] ?? Placement(
                location: nil,
                artifacts: [:],
                completeArtifacts: nil)
            let referenced = Set(conversation.artifacts.map(\.uuid))
            for (id, target) in durableTargets
            where referenced.contains(id) && placement.artifacts[id] == nil {
                placement.artifacts[id] = target
            }
            if placement.location != nil || !placement.artifacts.isEmpty
                || placement.completeArtifacts != nil {
                conversations[conversation.id] = placement
            }
        }
    }

    enum OperationFailure: Error, Equatable {
        case hydration(ConversationHydrationError)
        case unavailable
        case busy
    }

    typealias OperationResult = Result<Void, OperationFailure>

    private enum InvocationDirection: Equatable {
        case undo
        case redo
    }

    private struct OperationMoveGroup: Hashable {
        let memberKind: LibraryWorkspaceMoveOperationPayload.MemberKind
        let sourceWorkspaceID: UUID
        let destinationWorkspaceID: UUID
    }

    private final class Command: NSObject {
        var record: Record?
        var rollbackRecord: Record?
        var isStackRollback = false
        weak var undoManager: UndoManager?
        let actionName: String
        let conversations: ConversationStore
        let artifactStore: ArtifactStore?
        let operationDidFinish: ((OperationResult) -> Void)?

        init(
            record: Record?,
            actionName: String,
            conversations: ConversationStore,
            artifactStore: ArtifactStore?,
            operationDidFinish: ((OperationResult) -> Void)?
        ) {
            self.record = record
            self.actionName = actionName
            self.conversations = conversations
            self.artifactStore = artifactStore
            self.operationDidFinish = operationDidFinish
        }
    }

    private static var activeManagers: [ObjectIdentifier: Int] = [:]

    static func isApplying(on undoManager: UndoManager?) -> Bool {
        guard let undoManager else { return false }
        return activeManagers[ObjectIdentifier(undoManager), default: 0] > 0
    }

    /// Compatibility for Artifact-delete Undo. Move actions use `register`, whose acquisition path
    /// is off-main; this synchronous seam remains counted by ConversationStore until delete Undo is
    /// migrated in its own bounded checkpoint.
    @discardableResult
    static func apply(
        _ record: Record,
        conversations store: ConversationStore,
        artifactStore: ArtifactStore?
    ) -> Record {
        for id in record.conversationIDs where store.residentConversation(id) == nil {
            guard store.hydrateImmediately(id) != nil else { return Record() }
        }
        guard let inverse = inverseRecord(for: record, conversations: store, artifactStore: artifactStore),
              applyResident(record, conversations: store, artifactStore: artifactStore)
        else { return Record() }
        return inverse
    }

    /// Push a move receipt onto a Workspace stack. The optional completion is an internal
    /// deterministic test seam; UI failures use the store's existing binding-repair banner.
    static func register(
        _ record: Record,
        actionName: String,
        with undoManager: UndoManager?,
        conversations store: ConversationStore,
        artifactStore: ArtifactStore?,
        operationDidFinish: ((OperationResult) -> Void)? = nil
    ) {
        guard let undoManager,
              let changed = changedRecord(
                from: record,
                conversations: store,
                artifactStore: artifactStore),
              !changed.isEmpty else { return }
        let command = Command(
            record: changed,
            actionName: actionName,
            conversations: store,
            artifactStore: artifactStore,
            operationDidFinish: operationDidFinish)
        register(command, with: undoManager)
    }

    /// Forward adoption captures values as it traverses the ownership graph. Narrow that receipt to
    /// fields the move actually changed, so Undo cannot roll back a later move of an unrelated
    /// referenced artifact merely because it happened to share the same Conversation.
    private static func changedRecord(
        from record: Record,
        conversations store: ConversationStore,
        artifactStore: ArtifactStore?
    ) -> Record? {
        var changed = Record()
        for id in record.conversationIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard let current = store.residentConversation(id),
                  let before = record.conversations[id] else { return nil }
            var placement = Placement(location: nil, artifacts: [:], completeArtifacts: nil)
            if let location = before.location,
               location != ConversationLocation(
                    projectID: current.projectID,
                    cwd: current.cwd) {
                placement.location = location
            }
            let currentArtifacts = Dictionary(current.artifacts.map {
                ($0.uuid, ArtifactPlacement($0))
            }, uniquingKeysWith: { first, _ in first })
            for (artifactID, target) in before.artifacts
            where currentArtifacts[artifactID].map({ $0 != target }) == true {
                placement.artifacts[artifactID] = target
            }
            if placement.location != nil || !placement.artifacts.isEmpty {
                changed.setConversationPlacement(placement, for: id)
            }
        }
        if !record.artifacts.isEmpty {
            guard let artifactStore else { return nil }
            let current = Dictionary(artifactStore.artifacts.map {
                ($0.uuid, ArtifactPlacement($0))
            }, uniquingKeysWith: { first, _ in first })
            for (id, target) in record.artifacts {
                guard let value = current[id] else { return nil }
                if value != target { changed.setArtifactPlacement(target, for: id) }
            }
        }
        return changed
    }

    private static func register(_ command: Command, with undoManager: UndoManager) {
        command.undoManager = undoManager
        // Foundation does not promise to retain `target`; the registered closure owns the command
        // explicitly so an action can sit on the stack after this method returns.
        undoManager.registerUndo(withTarget: command) { [command] _ in
            MainActor.assumeIsolated { invoke(command) }
        }
        undoManager.setActionName(command.actionName)
    }

    private static func invoke(_ command: Command) {
        guard let undoManager = command.undoManager else { return }

        if command.isStackRollback {
            let restored = Command(
                record: command.rollbackRecord,
                actionName: command.actionName,
                conversations: command.conversations,
                artifactStore: command.artifactStore,
                operationDidFinish: command.operationDidFinish)
            register(restored, with: undoManager)
            return
        }

        guard let record = command.record else { return }
        let direction: InvocationDirection
        if undoManager.isUndoing {
            direction = .undo
        } else if undoManager.isRedoing {
            direction = .redo
        } else {
            assertionFailure("Workspace move command invoked outside Undo/Redo.")
            return
        }

        // This registration must happen before the AppKit callback returns. Its record is filled
        // only after every required Conversation is resident and the inverse has been captured.
        let opposite = Command(
            record: nil,
            actionName: command.actionName,
            conversations: command.conversations,
            artifactStore: command.artifactStore,
            operationDidFinish: command.operationDidFinish)
        register(opposite, with: undoManager)

        let managerID = ObjectIdentifier(undoManager)
        guard activeManagers[managerID, default: 0] == 0 else {
            compensate(
                failed: record,
                through: opposite,
                direction: direction,
                manager: undoManager,
                result: .failure(.busy),
                operationDidFinish: command.operationDidFinish,
                placementLease: nil,
                incrementActiveManager: false,
                decrementActiveManagerWhenDone: false)
            return
        }
        guard let lease = WorkspaceAdoption.beginPlacementOperation() else {
            compensate(
                failed: record,
                through: opposite,
                direction: direction,
                manager: undoManager,
                result: .failure(.busy),
                operationDidFinish: command.operationDidFinish,
                placementLease: nil,
                incrementActiveManager: true,
                decrementActiveManagerWhenDone: true)
            return
        }
        activeManagers[managerID, default: 0] += 1
        prepare(
            record,
            requiredIDs: record.conversationIDs,
            lease: lease,
            command: command,
            opposite: opposite,
            direction: direction,
            manager: undoManager)
    }

    private static func prepare(
        _ record: Record,
        requiredIDs: Set<UUID>,
        lease: WorkspacePlacementLease,
        command: Command,
        opposite: Command,
        direction: InvocationDirection,
        manager: UndoManager
    ) {
        let store = command.conversations
        store.withAcquiredConversations(requiredIDs) { result in
            guard case .success = result else {
                guard case .failure(let error) = result else { return }
                fail(
                    record,
                    through: opposite,
                    direction: direction,
                    manager: manager,
                    command: command,
                    lease: lease,
                    result: .failure(.hydration(error)))
                return
            }

            // Re-evaluate same-UUID holders after every hydration yield. Nested acquisitions install
            // their claims before the outer scope unwinds, so the complete graph stays pinned.
            let holderIDs = store.conversationIDs(
                referencingArtifactIDs: record.durableArtifactIDs)
            let expandedIDs = requiredIDs.union(holderIDs)
            if expandedIDs != requiredIDs {
                prepare(
                    record,
                    requiredIDs: expandedIDs,
                    lease: lease,
                    command: command,
                    opposite: opposite,
                    direction: direction,
                    manager: manager)
                return
            }

            var target = record
            for id in holderIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
                guard let current = store.residentConversation(id) else {
                    fail(
                        record,
                        through: opposite,
                        direction: direction,
                        manager: manager,
                        command: command,
                        lease: lease,
                        result: .failure(.unavailable))
                    return
                }
                target.mergeCurrentHolder(current, durableTargets: record.artifacts)
            }

            if store.usesApplicationSupportStore {
                if target.conversationIDs.contains(where: {
                    AgentBridge.hasBlockingWorkspaceMoveWork(for: $0)
                }) {
                    fail(
                        record,
                        through: opposite,
                        direction: direction,
                        manager: manager,
                        command: command,
                        lease: lease,
                        result: .failure(.busy))
                    return
                }
                for bridge in AgentBridge.live.allObjects {
                    guard let id = bridge.currentID, target.conversationIDs.contains(id) else {
                        continue
                    }
                    bridge.prepareForConversationWorkspaceAdoption(id)
                }
                let refreshedHolders = store.conversationIDs(
                    referencingArtifactIDs: record.durableArtifactIDs)
                let refreshedIDs = requiredIDs.union(refreshedHolders)
                if refreshedIDs != requiredIDs {
                    prepare(
                        record,
                        requiredIDs: refreshedIDs,
                        lease: lease,
                        command: command,
                        opposite: opposite,
                        direction: direction,
                        manager: manager)
                    return
                }
                for id in refreshedHolders.sorted(by: { $0.uuidString < $1.uuidString }) {
                    guard let current = store.residentConversation(id) else {
                        fail(
                            record,
                            through: opposite,
                            direction: direction,
                            manager: manager,
                            command: command,
                            lease: lease,
                            result: .failure(.unavailable))
                        return
                    }
                    target.mergeCurrentHolder(current, durableTargets: record.artifacts)
                }
            }

            let synchronousLoadsBefore = store.synchronousHydrationCount
            let operationCaptures = transientOperationCaptures(
                for: target,
                conversations: store,
                artifactStore: command.artifactStore,
                isUndo: direction == .undo)
            guard let inverse = inverseRecord(
                for: target,
                conversations: store,
                artifactStore: command.artifactStore),
                applyResident(
                    target,
                    conversations: store,
                    artifactStore: command.artifactStore)
            else {
                fail(
                    record,
                    through: opposite,
                    direction: direction,
                    manager: manager,
                    command: command,
                    lease: lease,
                    result: .failure(.unavailable))
                return
            }
            assert(
                store.synchronousHydrationCount == synchronousLoadsBefore,
                "Prepared Workspace Undo/Redo must not hydrate on the main actor.")
            LibraryTransientOperationCapturePublisher.publish(
                operationCaptures,
                afterConversations: target.conversationIDs,
                in: store,
                artifactIDs: target.durableArtifactIDs,
                in: command.artifactStore)
            opposite.record = inverse
            finishSuccess(command: command, manager: manager, lease: lease)
        }
    }

    private static func inverseRecord(
        for record: Record,
        conversations store: ConversationStore,
        artifactStore: ArtifactStore?
    ) -> Record? {
        var inverse = Record()
        for id in record.conversationIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard let current = store.residentConversation(id),
                  let target = record.conversations[id] else { return nil }
            inverse.capture(current, matching: target)
        }
        if !record.artifacts.isEmpty {
            guard let artifactStore else { return nil }
            let current = Dictionary(artifactStore.artifacts.map {
                ($0.uuid, $0)
            }, uniquingKeysWith: { first, _ in first })
            for id in record.durableArtifactIDs {
                guard let artifact = current[id] else { return nil }
                inverse.capture(artifacts: [id: artifact])
            }
        }
        return inverse
    }

    private static func transientOperationCaptures(
        for record: Record,
        conversations store: ConversationStore,
        artifactStore: ArtifactStore?,
        isUndo: Bool
    ) -> [LibraryTransientOperationCaptureFactory.Capture] {
        var grouped: [OperationMoveGroup: Set<UUID>] = [:]
        for id in record.conversationIDs {
            guard let current = store.residentConversation(id),
                  let destination = record.conversations[id]?.location else { continue }
            let sourceID = current.projectID ?? SQLiteLibraryStore.homeWorkspaceID
            let destinationID = destination.projectID ?? SQLiteLibraryStore.homeWorkspaceID
            guard sourceID != destinationID else { continue }
            grouped[OperationMoveGroup(
                memberKind: .conversation,
                sourceWorkspaceID: sourceID,
                destinationWorkspaceID: destinationID), default: []].insert(id)
        }
        if let artifactStore {
            let currentByID = Dictionary(uniqueKeysWithValues: artifactStore.artifacts.map {
                ($0.uuid, $0)
            })
            for id in record.durableArtifactIDs {
                guard let current = currentByID[id],
                      let destination = record.artifacts[id] else { continue }
                let sourceID = current.workspaceID ?? SQLiteLibraryStore.homeWorkspaceID
                let destinationID = destination.workspaceID
                    ?? SQLiteLibraryStore.homeWorkspaceID
                guard sourceID != destinationID else { continue }
                grouped[OperationMoveGroup(
                    memberKind: .artifact,
                    sourceWorkspaceID: sourceID,
                    destinationWorkspaceID: destinationID), default: []].insert(id)
            }
        }

        var captures: [LibraryTransientOperationCaptureFactory.Capture] = []
        for group in grouped.keys.sorted(by: {
            ($0.memberKind.rawValue, $0.sourceWorkspaceID.uuidString,
             $0.destinationWorkspaceID.uuidString)
                < ($1.memberKind.rawValue, $1.sourceWorkspaceID.uuidString,
                   $1.destinationWorkspaceID.uuidString)
        }) {
            guard let ids = grouped[group],
                  let capture = try? LibraryTransientOperationCaptureFactory.workspaceMove(
                    memberKind: group.memberKind,
                    memberIDs: ids,
                    sourceWorkspaceID: group.sourceWorkspaceID,
                    destinationWorkspaceID: group.destinationWorkspaceID,
                    isUndo: isUndo) else { continue }
            captures.append(capture)
        }
        return captures
    }

    /// Validate the whole transaction first, then change only placement fields on resident values.
    @discardableResult
    private static func applyResident(
        _ record: Record,
        conversations store: ConversationStore,
        artifactStore: ArtifactStore?
    ) -> Bool {
        guard record.conversationIDs.allSatisfy({ store.residentConversation($0) != nil }) else {
            return false
        }
        if !record.artifacts.isEmpty {
            guard let artifactStore else { return false }
            let existing = Set(artifactStore.artifacts.map(\.uuid))
            guard record.durableArtifactIDs.isSubset(of: existing) else { return false }
        }

        var updatedConversations: [Conversation] = []
        for id in record.conversationIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard let placement = record.conversations[id] else { return false }
            if let updated = store.updateResident(id, { conversation in
                if let location = placement.location {
                    conversation.projectID = location.projectID
                    conversation.cwd = location.cwd
                }
                if let complete = placement.completeArtifacts {
                    conversation.artifacts = complete
                } else {
                    for index in conversation.artifacts.indices {
                        let artifactID = conversation.artifacts[index].uuid
                        placement.artifacts[artifactID]?.apply(
                            to: &conversation.artifacts[index])
                    }
                }
            }) {
                updatedConversations.append(updated)
            }
        }

        var updatedArtifacts: [UUID: Artifact] = [:]
        if let artifactStore {
            for id in record.durableArtifactIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
                guard let placement = record.artifacts[id],
                      let updated = artifactStore.restoreWorkspacePlacement(placement, for: id)
                else { return false }
                updatedArtifacts[id] = updated
            }
        }

        guard store.usesApplicationSupportStore else { return true }
        synchronizeLiveState(
            record: record,
            updatedConversations: updatedConversations,
            updatedArtifacts: updatedArtifacts)
        return true
    }

    /// Mirror the forward cross-window handoff in the reverse direction. When the target Workspace
    /// already has a window, that window receives the Conversation and the current source viewer
    /// stays in its own Workspace; only without a receiver does the current viewer follow the record.
    private static func synchronizeLiveState(
        record: Record,
        updatedConversations: [Conversation],
        updatedArtifacts: [UUID: Artifact]
    ) {
        let updatedByID = Dictionary(updatedConversations.map { ($0.id, $0) },
                                     uniquingKeysWith: { first, _ in first })
        let bridges = AgentBridge.live.allObjects
        for bridge in bridges { bridge.applyArtifactWorkspaceAssignments(updatedArtifacts) }

        var groups: [ConversationLocation: Set<UUID>] = [:]
        for conversation in updatedConversations {
            if let placement = record.conversations[conversation.id],
               let location = placement.location {
                groups[location, default: []].insert(conversation.id)
            }
            PreviewRegistry.shared.sync(conversation.artifacts, conv: conversation.id)
        }

        for (location, ids) in groups.sorted(by: { lhs, rhs in
            let left = lhs.key.projectID?.uuidString ?? lhs.key.cwd
            let right = rhs.key.projectID?.uuidString ?? rhs.key.cwd
            return left < right
        }) {
            let snapshots = bridges.map {
                WorkspaceAdoptionLiveBridgeSnapshot(
                    bridgeID: $0.bridgeID,
                    hasWindow: $0.window != nil,
                    currentConversationID: $0.currentID,
                    projectID: $0.projectID,
                    cwd: $0.cwd)
            }
            if let plan = workspaceAdoptionLiveHandoffPlan(
                movedConversationIDs: ids,
                destinationProjectID: location.projectID,
                destinationCwd: location.cwd,
                bridges: snapshots),
               let receiver = bridges.first(where: { $0.bridgeID == plan.receivingBridgeID }) {
                let sourceIDs = Set(plan.sourceBridgeIDs)
                for bridge in bridges where sourceIDs.contains(bridge.bridgeID) {
                    bridge.relinquishConversationsAfterWorkspaceAdoption(ids)
                }
                if receiver.currentID != plan.revealConversationID {
                    receiver.select(plan.revealConversationID)
                }
            } else {
                for id in ids {
                    guard let conversation = updatedByID[id] else { continue }
                    for bridge in bridges where bridge.currentID == id {
                        bridge.applyConversationWorkspacePlacement(
                            conversation,
                            projectID: location.projectID,
                            cwd: location.cwd)
                    }
                }
            }
        }
    }

    private static func finishSuccess(
        command: Command,
        manager: UndoManager,
        lease: WorkspacePlacementLease
    ) {
        // `withAcquiredConversations` releases its claims after our callback returns. Keep the
        // process gate and menu busy state through that unwind, matching forward-move completion.
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                decrementActiveManager(manager)
                WorkspaceAdoption.endPlacementOperation(lease)
                command.operationDidFinish?(.success(()))
            }
        }
    }

    private static func fail(
        _ record: Record,
        through opposite: Command,
        direction: InvocationDirection,
        manager: UndoManager,
        command: Command,
        lease: WorkspacePlacementLease,
        result: OperationResult
    ) {
        compensate(
            failed: record,
            through: opposite,
            direction: direction,
            manager: manager,
            result: result,
            operationDidFinish: command.operationDidFinish,
            placementLease: lease,
            incrementActiveManager: false,
            decrementActiveManagerWhenDone: true)
    }

    private static func compensate(
        failed record: Record,
        through opposite: Command,
        direction: InvocationDirection,
        manager: UndoManager,
        result: OperationResult,
        operationDidFinish: ((OperationResult) -> Void)? = nil,
        placementLease: WorkspacePlacementLease?,
        incrementActiveManager: Bool,
        decrementActiveManagerWhenDone: Bool
    ) {
        opposite.isStackRollback = true
        opposite.rollbackRecord = record
        let managerID = ObjectIdentifier(manager)
        if incrementActiveManager { activeManagers[managerID, default: 0] += 1 }
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                switch direction {
                case .undo: manager.redo()
                case .redo: manager.undo()
                }
                if decrementActiveManagerWhenDone { decrementActiveManager(manager) }
                if let placementLease {
                    WorkspaceAdoption.endPlacementOperation(placementLease)
                }
                presentFailureIfNeeded(
                    result,
                    direction: direction,
                    conversations: opposite.conversations)
                operationDidFinish?(result)
            }
        }
    }

    private static func presentFailureIfNeeded(
        _ result: OperationResult,
        direction: InvocationDirection,
        conversations: ConversationStore
    ) {
        guard conversations.usesApplicationSupportStore,
              case .failure(let failure) = result else { return }
        if case .hydration = failure {
            // ConversationStore already published the durable repair/retry banner.
            return
        }
        let verb = direction == .undo ? "undone" : "redone"
        let alert = NSAlert()
        alert.messageText = "Move couldn’t be \(verb)"
        switch failure {
        case .busy:
            alert.informativeText =
                "No items changed. Wait for the active work or Workspace operation to finish, then try again."
        case .unavailable:
            alert.informativeText =
                "No items changed because a Conversation or artifact is no longer available. Restore it, then try again."
        case .hydration:
            return
        }
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private static func decrementActiveManager(_ manager: UndoManager) {
        let id = ObjectIdentifier(manager)
        let remaining = activeManagers[id, default: 1] - 1
        activeManagers[id] = remaining > 0 ? remaining : nil
    }

    /// Menu wording. AppKit prefixes “Undo ”/“Redo ”.
    static func actionName(conversations count: Int) -> String {
        String(localized: "Move \(count) Conversations")
    }

    static func actionName(artifacts count: Int) -> String {
        String(localized: "Move \(count) Artifacts")
    }
}
