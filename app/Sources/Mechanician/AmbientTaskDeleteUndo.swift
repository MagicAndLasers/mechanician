import Foundation

/// Putting a deleted scheduled task back, and taking it away again.
///
/// A scheduled task is a configured automation — a trigger, a prompt, a workspace binding, and its
/// run history — and deleting one was a single unconfirmed click onto a hard `removeAll`. Every
/// other destructive action in the app is recoverable: conversations and artifacts move to a trash
/// with a receipt, workspace moves register an undo. This gives tasks the same footing.
///
/// The task value *is* the receipt: unlike a conversation there are no bytes on disk to relocate, so
/// restoring is re-inserting the value at the position it held. Undo and redo alternate by
/// registering each other, the same shape `ConversationDeleteUndo` and `WorkspaceMoveUndo` use.
@MainActor
enum AmbientTaskDeleteUndo {
    /// AppKit composes "Undo " plus this.
    static var actionName: String { String(localized: "Delete Scheduled Task") }

    static func register(
        _ task: ScheduledTask,
        at index: Int,
        store: AmbientStore,
        undoManager: UndoManager?
    ) {
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: store) { target in
            MainActor.assumeIsolated {
                target.reinsert(task, at: index)
                // Registered while undoing, so this becomes the redo.
                registerRedo(id: task.id, store: target, undoManager: undoManager)
            }
        }
        undoManager.setActionName(actionName)
    }

    private static func registerRedo(
        id: String,
        store: AmbientStore,
        undoManager: UndoManager
    ) {
        undoManager.registerUndo(withTarget: store) { target in
            MainActor.assumeIsolated {
                // Re-read the position rather than reusing the old one: the list may have changed
                // while the delete was undone, and restoring to a stale index would reorder it.
                guard let index = target.tasks.firstIndex(where: { $0.id == id }) else { return }
                let task = target.tasks[index]
                target.delete(id)
                register(task, at: index, store: target, undoManager: undoManager)
            }
        }
        undoManager.setActionName(actionName)
    }
}
