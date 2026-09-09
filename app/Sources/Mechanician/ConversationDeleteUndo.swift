import Foundation

/// Putting deleted conversations back, and taking them away again.
///
/// A delete is reversible because `ConversationStore.remove` moves the sidecar and media into the
/// trash rather than unlinking them, and hands back a receipt. This is the piece that puts those
/// receipts on a workspace's undo stack.
///
/// Undo and redo alternate by registering each other, the same shape `WorkspaceMoveUndo` uses.
/// Redo re-deletes by id and captures **fresh** receipts rather than reusing the old ones, because
/// each delete gets its own trash slot — reusing a spent slot is what let a conversation come back
/// on the next launch.
@MainActor
enum ConversationDeleteUndo {
    /// AppKit composes "Undo " plus this. The singular/plural split is declared in the catalogue,
    /// not written here: English needs two forms and several languages need up to six, so a
    /// `count == 1` ternary is a defect the moment this is translated.
    static func actionName(count: Int) -> String {
        String(localized: "Delete \(count) Conversations")
    }

    /// Separate from the counted form on purpose: the user chose "all", so the name should say so
    /// rather than report a number they never picked.
    static var deleteAllActionName: String { String(localized: "Delete All Conversations") }

    static func register(
        _ receipts: [ConversationDeleteReceipt],
        actionName: String,
        store: ConversationStore,
        undoManager: UndoManager?
    ) {
        guard let undoManager, !receipts.isEmpty else { return }
        undoManager.registerUndo(withTarget: store) { target in
            MainActor.assumeIsolated {
                for receipt in receipts { target.restore(receipt) }
                // Registered while undoing, so this becomes the redo.
                registerRedo(
                    ids: receipts.map(\.conversation.id),
                    actionName: actionName,
                    store: target,
                    undoManager: undoManager)
            }
        }
        undoManager.setActionName(actionName)
    }

    private static func registerRedo(
        ids: [UUID],
        actionName: String,
        store: ConversationStore,
        undoManager: UndoManager
    ) {
        undoManager.registerUndo(withTarget: store) { target in
            MainActor.assumeIsolated {
                // Fresh receipts: a spent trash slot must never be reused. Restored records can be
                // evicted before Redo; acquire those bytes serially off-main instead of decoding a
                // whole selection inside AppKit's undo callback.
                target.removeSequentially(ids) { receipts in
                    register(
                        receipts,
                        actionName: actionName,
                        store: target,
                        undoManager: undoManager)
                }
            }
        }
        undoManager.setActionName(actionName)
    }
}

/// Putting deleted artifacts back, and taking them away again.
///
/// Separate from the conversation case because the entanglement is different. `ArtifactStore`
/// carries a resurrection guard — `mutationGeneration` plus `pendingDeleteIDs` — whose whole job is
/// to stop an in-flight reload from bringing a deleted file back. Undo has to land *inside* that
/// guard rather than beside it, and it does: `restore` goes through `persist`, which bumps the
/// generation and clears the pending-delete entry.
@MainActor
enum ArtifactDeleteUndo {
    static func actionName(count: Int) -> String {
        String(localized: "Delete \(count) Artifacts")
    }

    static func register(
        _ receipts: [ArtifactDeleteReceipt],
        actionName: String,
        store: ArtifactStore,
        conversations: ConversationStore,
        undoManager: UndoManager?
    ) {
        guard let undoManager, !receipts.isEmpty else { return }
        undoManager.registerUndo(withTarget: store) { target in
            MainActor.assumeIsolated {
                for receipt in receipts {
                    target.restore(receipt, conversations: conversations)
                }
                registerRedo(
                    ids: receipts.map(\.artifact.uuid),
                    actionName: actionName,
                    store: target,
                    conversations: conversations,
                    undoManager: undoManager)
            }
        }
        undoManager.setActionName(actionName)
    }

    private static func registerRedo(
        ids: [UUID],
        actionName: String,
        store: ArtifactStore,
        conversations: ConversationStore,
        undoManager: UndoManager
    ) {
        undoManager.registerUndo(withTarget: store) { target in
            MainActor.assumeIsolated {
                let receipts = ids.compactMap {
                    target.delete($0, conversations: conversations)
                }
                register(
                    receipts,
                    actionName: actionName,
                    store: target,
                    conversations: conversations,
                    undoManager: undoManager)
            }
        }
        undoManager.setActionName(actionName)
    }
}
