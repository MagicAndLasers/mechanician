import Foundation

/// One top-level transcript presentation span. Routine consecutive tool calls collapse into one
/// activity row; provider-reported Workflow cards and every conversational entry retain their own
/// row and therefore their own semantics.
struct TranscriptRowSpan: Equatable {
    enum Kind: Equatable { case entry, activity }

    let kind: Kind
    let range: Range<Int>
}

/// Build stable display spans without parsing tool payloads. Tool inputs/results can be very large,
/// so grouping is deliberately identity/kind-only; titles are derived lazily if a visible activity
/// group is opened.
func transcriptRowSpans(_ entries: [TranscriptEntry]) -> [TranscriptRowSpan] {
    var spans: [TranscriptRowSpan] = []
    spans.reserveCapacity(entries.count)
    var index = entries.startIndex

    while index < entries.endIndex {
        guard isGroupableActivity(entries[index]) else {
            spans.append(TranscriptRowSpan(kind: .entry, range: index..<(index + 1)))
            index += 1
            continue
        }

        var end = index + 1
        while end < entries.endIndex, isGroupableActivity(entries[end]) {
            end += 1
        }
        let run = index..<end
        // A routine tool must start as an Activity row even when it is temporarily the only
        // action in the run. Rendering the first action as a SwiftUI tool card and replacing it
        // with a short native Activity header when the second action arrived caused the transcript
        // tail to jump during generation. Keeping one presentation kind and row identity from the
        // first action lets later actions extend the group without changing its geometry class.
        spans.append(TranscriptRowSpan(kind: .activity, range: run))
        index = end
    }
    return spans
}

private func isGroupableActivity(_ entry: TranscriptEntry) -> Bool {
    guard entry.kind == .tool else { return false }
    // Workflow is a real provider-owned aggregate with its own live card. Folding it into a
    // Mechanician activity summary would discard provider truth and recreate the synthetic-workflow
    // problem removed in an earlier refactor. ImageGeneration is also standalone: its durable
    // preview belongs directly in the transcript rather than behind the native activity disclosure.
    return entry.toolName != "Workflow" && entry.toolName != "ImageGeneration"
}

/// Terminalize tool calls whose provider turn ended without a matching result. This is used at
/// turn termination and while adopting durable history; it never touches a result-bearing row.
@discardableResult
func stopUnfinishedToolEntries(
    _ entries: inout [TranscriptEntry],
    captureOrdinal: UInt64? = nil
) -> Bool {
    var changed = false
    for index in entries.indices where
        entries[index].kind == .tool && entries[index].toolResult == nil
    {
        guard entries[index].toolState != .stopped else { continue }
        entries[index].toolState = .stopped
        entries[index].toolTerminalCaptureOrdinal = captureOrdinal
        changed = true
    }
    return changed
}

/// Match a provider result to its stable tool id. Falling back to the last unresolved tool is only
/// for legacy provider events that genuinely lack an id; an id must never complete a different row.
func toolEntryIndex(for toolUseID: String?, in entries: [TranscriptEntry]) -> Int? {
    if let toolUseID, !toolUseID.isEmpty {
        return entries.lastIndex { $0.kind == .tool && $0.toolUseId == toolUseID }
    }
    return entries.lastIndex { $0.kind == .tool && $0.toolResult == nil }
}
