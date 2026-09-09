import Foundation

/// Where a deleted conversation waits so undo can put it back.
///
/// Deleting used to unlink the sidecar and `rm -rf` the conversation's media directory. A purely
/// in-memory snapshot could not restore that: every pasted image and attached file would come back
/// as a dangling reference. So a delete moves both aside instead, and undo moves them home.
///
/// **A fresh directory per delete, never one keyed by conversation id.** Redo after an undo would
/// otherwise move a sidecar onto a destination that still holds the previous copy. `moveItem` fails
/// on an existing destination, and that failure was swallowed by `try?` — leaving the sidecar in the
/// store directory while the row was dropped from memory, so the conversation reappeared on the next
/// launch. The token is what makes redo safe.
struct ConversationTrash: Sendable {
    /// `<app support>/trash/conversations`. Derived from the store's own base, never hardcoded, or a
    /// dev build would trash into the real store.
    let root: URL

    /// A directory nothing else will claim, for one delete.
    func makeSlot(for conversationID: UUID) throws -> URL {
        let slot = root.appendingPathComponent(
            "\(conversationID.uuidString)-\(UUID().uuidString)",
            isDirectory: true)
        try FileManager.default.createDirectory(at: slot, withIntermediateDirectories: true)
        return slot
    }

    /// Move a file into `slot`, keeping its name. Throws rather than swallowing: a delete that
    /// silently fails to move the sidecar leaves it readable on the next launch.
    func take(_ url: URL, into slot: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let destination = slot.appendingPathComponent(url.lastPathComponent)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: url, to: destination)
    }

    /// Move a file back out of `slot` to `destination`.
    func give(_ name: String, from slot: URL, to destination: URL) throws {
        let source = slot.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: source.path) else { return }
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: source, to: destination)
    }

    func discard(_ slot: URL) {
        try? FileManager.default.removeItem(at: slot)
    }

    /// Drop slots older than `age`. Called once at launch: undo is a within-session affordance, and
    /// without this the trash would grow for the life of the install.
    func reap(olderThan age: TimeInterval, now: Date = Date()) {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles])) ?? []
        for entry in entries {
            let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            guard let modified, now.timeIntervalSince(modified) > age else { continue }
            try? FileManager.default.removeItem(at: entry)
        }
    }
}

/// Everything undo needs to put one deleted conversation back.
struct ConversationDeleteReceipt: Sendable {
    /// The whole value as it stood, so restore does not have to reconstruct it.
    let conversation: Conversation
    /// The trash directory holding its sidecar and media.
    let slot: URL
    /// Whether its prompt queue was paused before the delete.
    let wasQueuePaused: Bool
    /// Exact SQLite authority rows removed by the cascading delete. Legacy receipts carry none.
    /// This is intentionally in-session only; permanent deletion never constructs a receipt.
    let workEvidence: [ConversationWorkEvidence]
}

/// Everything undo needs to put one deleted artifact back.
struct ArtifactDeleteReceipt: Sendable {
    /// The durable record as it stood.
    let artifact: Artifact
    /// Every conversation that referenced it, as it stood before the delete pruned the reference.
    let conversations: WorkspaceMoveUndo.Record
}
