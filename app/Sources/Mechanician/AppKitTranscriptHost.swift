import AppKit
import OSLog
import SwiftUI

private struct TranscriptRowHeightInvalidationKey: EnvironmentKey {
    static let defaultValue: @MainActor () -> Void = {}
}

extension EnvironmentValues {
    /// Stateful SwiftUI controls hosted inside an AppKit transcript row use this after changing
    /// their ideal height. NSTableView otherwise retains the last externally measured row height
    /// because the hosting view deliberately fills that finite frame.
    var invalidateTranscriptRowHeight: @MainActor () -> Void {
        get { self[TranscriptRowHeightInvalidationKey.self] }
        set { self[TranscriptRowHeightInvalidationKey.self] = newValue }
    }
}

/// AppKit owns transcript scrolling, document geometry, and row reuse. SwiftUI is intentionally
/// limited to isolated row renderers, so unrelated view updates cannot replace the
/// scroll surface and long conversations do not keep every transcript row realized.
struct AppKitTranscriptChunk: Identifiable {
    let id: AnyHashable
    let revision: Int
    let sourceIndex: Int
    let hostedHeightEstimateClass: AppKitHostedHeightEstimateClass
    /// Exact Workflow tool-use identity for the one kind of historical transcript row whose
    /// presentation changes without a transcript generation. The projection cache uses this key
    /// to refresh only those rows when delegated progress arrives instead of rebuilding every row
    /// in a long conversation on the main thread.
    let workflowToolUseID: String?
    /// How much content this row carries, in UTF-8 bytes of its entry text. The one input the
    /// height estimate has that actually varies with how tall the row will be. It is a projection
    /// input rather than something the host derives, because the host deliberately never sees the
    /// entry — only the SwiftUI closure that renders it.
    let contentMetric: Int
    let activityGroup: AppKitActivityGroup?
    let assistant: AppKitAssistantContent?

    init(id: AnyHashable,
         revision: Int,
         sourceIndex: Int = 0,
         hostedHeightEstimateClass: AppKitHostedHeightEstimateClass = .standard,
         contentMetric: Int = 0,
         workflowToolUseID: String? = nil,
         activityGroup: AppKitActivityGroup? = nil,
         assistant: AppKitAssistantContent? = nil) {
        self.id = id
        self.revision = revision
        self.sourceIndex = sourceIndex
        self.hostedHeightEstimateClass = hostedHeightEstimateClass
        self.contentMetric = contentMetric
        self.workflowToolUseID = workflowToolUseID
        self.activityGroup = activityGroup
        self.assistant = assistant
    }
}

/// WHICH SHAPE a hosted row is, for the unmeasured-height guess.
///
/// This was two cases — a Workflow card, and everything else — and "everything else" is where the
/// upward scroll came apart. `bubble(_:)` renders a one-line user message, a tool card, a
/// permission prompt, a question, a compaction notice and a system error through the same host, so
/// a single running mean had to stand in for all of them at once. A guess wrong by a factor of five
/// is a card that visibly resizes the moment the reader reaches it.
///
/// Splitting by entry kind costs nothing at runtime and gives each shape its own mean. It is only
/// safe because `heightOfRow` now falls back to the POOLED mean across every shape rather than to
/// the table's 44-point default: a kind nobody has scrolled to yet must never reintroduce the
/// 44-point lurch this whole mechanism exists to prevent.
///
/// Workflow stays separate from its own `.tool` kind deliberately. An expanded Workflow can be
/// thousands of points tall; letting that measurement speak for a newly appended provider-status
/// row makes the pinned viewport overshoot and snap backward.
enum AppKitHostedHeightEstimateClass: Hashable {
    case workflow
    case kind(String)

    /// The shape a caller means when it has no entry to classify. Kept as a name because the
    /// chunk initializer and the tests both spell it.
    static let standard = AppKitHostedHeightEstimateClass.kind("")

    init(entry: TranscriptEntry) {
        self = entry.kind == .tool && entry.toolName == "Workflow"
            ? .workflow
            : .kind(entry.kind.rawValue)
    }
}

/// What one row shape has taught us about how tall its rows are.
///
/// A single running mean is what shipped before, and for a shape whose rows genuinely differ by two
/// orders of magnitude — an assistant answer is five characters or forty thousand — one scalar
/// cannot be close to right for both ends. Measured on the real library, `.assistant` alone is 47%
/// of rows in a long conversation, with text from 5 to 41,431 characters against one mean.
///
/// So each shape also fits a straight line through (content size, height): ordinary least squares
/// over the same bounded sample budget, no extra measurement pass, one multiply to evaluate. The
/// mean stays and remains the answer whenever the line has nothing to say — too few samples, or
/// every sample at the same content size, which is exactly the fixed-height shapes (an activity
/// header is an activity header).
private struct AppKitTranscriptHeightEstimate {
    /// Bounded for the reason the running mean always was: changing a shape's guess invalidates
    /// every still-unmeasured row of that shape, which is O(n) in the transcript. The 33rd sample
    /// does not tell you enough to pay for that again.
    static let sampleBudget: CGFloat = 32
    /// Below this the fit has no support and the plain mean is the honest answer.
    private static let minimumFitSamples: CGFloat = 4

    private(set) var count: CGFloat = 0
    private(set) var mean: CGFloat = 0
    private var sumX: CGFloat = 0
    private var sumY: CGFloat = 0
    private var sumXX: CGFloat = 0
    private var sumXY: CGFloat = 0
    private var minHeight: CGFloat = .greatestFiniteMagnitude
    private var maxHeight: CGFloat = 0

    var isEmpty: Bool { count == 0 }
    var isFull: Bool { count >= Self.sampleBudget }

    mutating func add(height: CGFloat, metric: CGFloat) {
        count += 1
        mean += (height - mean) / count
        sumX += metric
        sumY += height
        sumXX += metric * metric
        sumXY += metric * height
        minHeight = Swift.min(minHeight, height)
        maxHeight = Swift.max(maxHeight, height)
    }

    /// The fitted height for this content size, or the plain mean when the fit has nothing to stand
    /// on. Clamped to the range this shape has actually been seen in, widened once in each
    /// direction: extrapolating past the samples is the entire point, but a degenerate fit must not
    /// be allowed to propose a negative or an absurd row.
    func height(for metric: CGFloat) -> CGFloat? {
        guard count > 0 else { return nil }
        guard count >= Self.minimumFitSamples else { return mean }
        let denominator = count * sumXX - sumX * sumX
        guard denominator > 0.0001 else { return mean }
        let slope = (count * sumXY - sumX * sumY) / denominator
        let intercept = (sumY - slope * sumX) / count
        let fitted = intercept + slope * metric
        guard fitted.isFinite else { return mean }
        return Swift.min(Swift.max(fitted, Swift.max(1, minHeight / 2)), maxHeight * 2)
    }
}

struct AppKitAssistantContent {
    let text: String
    let chatScale: CGFloat
    let isLive: Bool
    let canRetry: Bool
    let canFork: Bool
    /// Whether this answer was given remembered statements, and so has an outcome to record.
    ///
    /// Most answers are not: the controls appear only where a verdict would land on something,
    /// rather than inviting a judgement that goes nowhere.
    let cwd: String
    let eyebrow: String?
    let isReview: Bool
    /// Exact provider-text append metadata. This is presentation-only and is present only when the
    /// coordinator consumed every transcript generation since the document it currently displays.
    /// A nil value means the cell must compare/rebuild from `text`, which remains canonical.
    let tailAppend: TranscriptTailAppend?
    let transcriptGeneration: UInt64?

    init(
        text: String,
        chatScale: CGFloat,
        isLive: Bool,
        canRetry: Bool,
        canFork: Bool = true,
        cwd: String,
        eyebrow: String? = nil,
        isReview: Bool = false,
        tailAppend: TranscriptTailAppend? = nil,
        transcriptGeneration: UInt64? = nil
    ) {
        self.text = text
        self.chatScale = chatScale
        self.isLive = isLive
        self.canRetry = canRetry
        self.canFork = canFork
        self.cwd = cwd
        self.eyebrow = eyebrow
        self.isReview = isReview
        self.tailAppend = tailAppend
        self.transcriptGeneration = transcriptGeneration
    }

    func withoutTailAppend() -> AppKitAssistantContent {
        AppKitAssistantContent(
            text: text,
            chatScale: chatScale,
            isLive: isLive,
            canRetry: canRetry,
            canFork: canFork,
            cwd: cwd,
            eyebrow: eyebrow,
            isReview: isReview,
            transcriptGeneration: transcriptGeneration)
    }
}

/// One canonical tail-row snapshot carried beside a stable full-transcript projection. The latest
/// exact append lets an already-synchronized coordinator update in O(1); a new or lagging
/// coordinator installs `chunk` canonically and rejoins at `generation`.
struct AppKitTranscriptTailUpdate {
    let generation: UInt64
    let chunk: AppKitTranscriptChunk
    let append: TranscriptTailAppend
}

/// Row-scoped Workflow presentation changes carried beside a stable full-transcript projection.
/// Workflow progress lives outside the transcript ledger; this channel lets the native host
/// reload the exact affected cards without projecting or diffing the whole conversation.
struct AppKitTranscriptWorkflowUpdate {
    let generation: UInt64
    let chunks: [AppKitTranscriptChunk]
}

/// The full row projection is retained while an assistant tail grows. `projectionRevision` changes
/// whenever any structural or presentation input requires a canonical rebuild; ordinary exact
/// appends keep the same base array and travel through `tailUpdate` only.
struct AppKitTranscriptProjection {
    /// `projectionRevision` is local to one cache lifetime. SwiftUI may recreate that cache while
    /// retaining the native representable/coordinator, so the coordinator needs both values to
    /// distinguish a genuinely unchanged projection from a replacement cache's first revision.
    let cacheID: UUID
    let chunks: [AppKitTranscriptChunk]
    let chunksGeneration: UInt64
    let projectionRevision: UInt64
    let tailUpdate: AppKitTranscriptTailUpdate?
    let workflowUpdate: AppKitTranscriptWorkflowUpdate?
}

/// Per-window presentation cache. It never owns transcript truth: every mismatch invokes the
/// caller's canonical projection closure and replaces the entire baseline.
@MainActor
final class AppKitTranscriptProjectionCache<Key: Equatable> {
    private let cacheID = UUID()
    private var key: Key?
    private var chunks: [AppKitTranscriptChunk] = []
    private var chunksGeneration: UInt64 = 0
    private var currentGeneration: UInt64 = 0
    private var projectionRevision: UInt64 = 0
    private var currentTailEntryID: UUID?
    private var currentTailUTF8Count: Int?
    private var tailUpdate: AppKitTranscriptTailUpdate?
    private var lastAppendGeneration: UInt64?
    private var workflowChunkIndices: [Int] = []
    private var workflowUpdateGeneration: UInt64 = 0
    private var workflowUpdate: AppKitTranscriptWorkflowUpdate?

    private(set) var canonicalProjectionCountForTesting = 0
    private(set) var exactTailUpdateCountForTesting = 0

    func project(
        key nextKey: Key,
        generation: UInt64,
        append: TranscriptTailAppend?,
        conversationID: UUID?,
        tailEntry: TranscriptEntry?,
        canonical: () -> [AppKitTranscriptChunk],
        tailChunk: (TranscriptEntry, TranscriptTailAppend) -> AppKitTranscriptChunk?,
        workflowChunk: ((Int, String) -> AppKitTranscriptChunk?)? = nil
    ) -> AppKitTranscriptProjection {
        if key == nextKey,
           let append,
           append.conversationID == conversationID,
           append.baseGeneration == currentGeneration,
           append.generation == generation,
           append.entryID == currentTailEntryID,
           append.baseUTF8Count == currentTailUTF8Count,
           append.resultingUTF8Count == tailEntry?.text.utf8.count,
           append.delta.utf8.count == append.resultingUTF8Count - append.baseUTF8Count,
           let tailEntry,
           tailEntry.id == append.entryID,
           let nextTail = tailChunk(tailEntry, append),
           nextTail.id == chunks.last?.id,
           nextTail.assistant != nil {
            refreshWorkflowChunks(using: workflowChunk)
            currentGeneration = generation
            currentTailUTF8Count = append.resultingUTF8Count
            lastAppendGeneration = append.generation
            tailUpdate = AppKitTranscriptTailUpdate(
                generation: generation,
                chunk: nextTail,
                append: append)
            exactTailUpdateCountForTesting += 1
            return projection()
        }

        if key == nextKey,
           generation == currentGeneration,
           append?.generation == lastAppendGeneration {
            refreshWorkflowChunks(using: workflowChunk)
            return projection()
        }

        chunks = canonical()
        workflowChunkIndices = chunks.indices.filter {
            chunks[$0].workflowToolUseID != nil
        }
        key = nextKey
        chunksGeneration = generation
        currentGeneration = generation
        currentTailEntryID = tailEntry?.id
        currentTailUTF8Count = tailEntry?.text.utf8.count
        tailUpdate = nil
        workflowUpdate = nil
        lastAppendGeneration = append?.generation
        projectionRevision &+= 1
        canonicalProjectionCountForTesting += 1
        return projection()
    }

    /// Workflow progress is owned outside the transcript ledger, so its card can change while the
    /// transcript generation remains fixed. Refreshing the exact keyed rows here keeps that card
    /// live without paying the old O(transcript) canonical projection cost for every phase, token,
    /// and tool update.
    private func refreshWorkflowChunks(
        using refresh: ((Int, String) -> AppKitTranscriptChunk?)?
    ) {
        guard let refresh, !workflowChunkIndices.isEmpty else { return }
        var changed = false
        for index in workflowChunkIndices {
            guard chunks.indices.contains(index),
                  let toolUseID = chunks[index].workflowToolUseID,
                  let next = refresh(chunks[index].sourceIndex, toolUseID),
                  next.id == chunks[index].id else { continue }
            guard next.revision != chunks[index].revision else { continue }
            chunks[index] = next
            changed = true
        }
        if changed {
            workflowUpdateGeneration &+= 1
            workflowUpdate = AppKitTranscriptWorkflowUpdate(
                generation: workflowUpdateGeneration,
                // A SwiftUI representable may coalesce parent updates. Carry the latest complete
                // snapshot of every keyed Workflow row so skipping one update can never strand a
                // different card at an older revision.
                chunks: workflowChunkIndices.map { chunks[$0] })
        }
    }

    private func projection() -> AppKitTranscriptProjection {
        AppKitTranscriptProjection(
            cacheID: cacheID,
            chunks: chunks,
            chunksGeneration: chunksGeneration,
            projectionRevision: projectionRevision,
            tailUpdate: tailUpdate,
            workflowUpdate: workflowUpdate)
    }
}

struct AppKitActivityGroup: Equatable {
    let id: AnyHashable
    let actions: [AppKitActivityAction]
    let chatScale: CGFloat

    var isRunning: Bool { actions.contains { $0.state == .running } }
    var failedCount: Int { actions.count { $0.state == .failed } }
    var stoppedCount: Int { actions.count { $0.state == .stopped } }
    var refusedCount: Int { actions.count { $0.state == .refused } }
    var supersededCount: Int { actions.count { $0.isSuperseded } }
}

struct AppKitActivityAction: Equatable {
    /// `refused` is deliberately not a kind of `failed`. The person declining a call and the call
    /// breaking are different events, and a red "failed" on something that never ran is the app
    /// reporting an error it invented.
    enum State: Equatable { case running, succeeded, failed, stopped, refused }

    let id: AnyHashable
    let sourceIndex: Int
    let toolName: String
    let rawInput: String
    let state: State
    let isSuperseded: Bool
    let revision: Int

    init(id: AnyHashable,
         sourceIndex: Int,
         toolName: String,
         rawInput: String,
         state: State,
         isSuperseded: Bool = false,
         revision: Int = 0) {
        self.id = id
        self.sourceIndex = sourceIndex
        self.toolName = toolName
        self.rawInput = rawInput
        self.state = state
        self.isSuperseded = isSuperseded
        self.revision = revision
    }
}

private struct ActivityActionPresentationID: Hashable {
    let groupID: AnyHashable
    let actionID: AnyHashable
}

private struct AppKitTranscriptPresentationRow {
    enum Kind {
        case transcript(
            sourceIndex: Int,
            estimateClass: AppKitHostedHeightEstimateClass,
            contentMetric: Int)
        case assistant(sourceIndex: Int, content: AppKitAssistantContent)
        case activityHeader(group: AppKitActivityGroup, expanded: Bool)
        case activityAction(
            groupID: AnyHashable,
            action: AppKitActivityAction,
            expanded: Bool,
            isLast: Bool,
            chatScale: CGFloat)
    }

    let id: AnyHashable
    let revision: Int
    let kind: Kind

    /// A revision is the caller's cheap content invalidation token, but it is not the complete
    /// native-cell configuration. In particular, a cold recent-page preview and the subsequently
    /// hydrated transcript share entry IDs/revisions while changing page-relative source indexes
    /// and enabling terminal actions. Preserve that fast token without allowing an equal revision
    /// to keep a preview-configured cell after the full transcript arrives.
    func hasSameCellConfiguration(as other: AppKitTranscriptPresentationRow) -> Bool {
        guard revision == other.revision else { return false }
        switch (kind, other.kind) {
        case let (.transcript(sourceIndex, _, _),
                  .transcript(otherSourceIndex, _, _)):
            return sourceIndex == otherSourceIndex

        case let (.assistant(sourceIndex, content),
                  .assistant(otherSourceIndex, otherContent)):
            return sourceIndex == otherSourceIndex
                && content.chatScale == otherContent.chatScale
                && content.isLive == otherContent.isLive
                && content.canRetry == otherContent.canRetry
                && content.canFork == otherContent.canFork
                && content.cwd == otherContent.cwd
                && content.eyebrow == otherContent.eyebrow
                && content.isReview == otherContent.isReview

        case (.activityHeader, .activityHeader):
            return true

        case let (.activityAction(_, action, _, _, _),
                  .activityAction(_, otherAction, _, _, _)):
            // The revision owns visible activity state. The page-relative callback index is the
            // one configuration value a cold preview can change without changing that revision.
            return action.sourceIndex == otherAction.sourceIndex

        default:
            return false
        }
    }

    /// Which SHAPE of row this is, for the unmeasured-height estimate. Not the identity — every
    /// assistant answer shares one key, which is the whole point: what one of them measured is the
    /// best guess available for the next one.
    var estimateKey: AppKitTranscriptHeightEstimateKey {
        switch kind {
        case .transcript(_, let estimateClass, _): return .hosted(estimateClass)
        case .assistant: return .assistant
        case .activityHeader: return .activityHeader
        case .activityAction: return .activityAction
        }
    }

    /// HOW MUCH CONTENT this row carries, as the estimate's independent variable. Text bytes,
    /// because text length is what a wrapped transcript row's height is very nearly linear in.
    ///
    /// Zero is a real answer, not a missing one: an activity header is the same height whatever it
    /// summarizes, and a shape whose samples all report zero simply falls back to its mean, which
    /// is exactly right for a fixed-height row.
    var heightMetric: Int {
        switch kind {
        case .transcript(_, _, let contentMetric): return contentMetric
        case .assistant(_, let content): return content.text.utf8.count
        case .activityHeader, .activityAction: return 0
        }
    }
}

private enum AppKitTranscriptHeightEstimateKey: Hashable {
    case hosted(AppKitHostedHeightEstimateClass)
    case assistant
    case activityHeader
    case activityAction
}

@MainActor
struct AppKitTranscriptHost: NSViewRepresentable {
    let chunks: [AppKitTranscriptChunk]
    let chunksGeneration: UInt64?
    let projectionCacheID: UUID?
    let projectionRevision: UInt64?
    let tailUpdate: AppKitTranscriptTailUpdate?
    let workflowUpdate: AppKitTranscriptWorkflowUpdate?
    let pin: TranscriptPinController
    /// Find's one input. Carried as a value the view already re-renders on, rather than a back
    /// channel into the Coordinator, so a reveal cannot race the row rebuild it depends on.
    let revealRequest: AgentBridge.TranscriptRevealRequest?
    /// `(token, succeeded)`. A `false` means the match has no row today and the find bar should step
    /// past it rather than sit on a selection nothing on screen corresponds to.
    let onRevealResult: (Int, Bool) -> Void
    /// Fires after the coordinator has synchronized its native row model. This does not force
    /// layout/display and therefore deliberately does not claim WindowServer compositor paint.
    let onPresentationSync: () -> Void
    let activityDetail: (Int) -> AnyView
    let retryAssistant: (Int) -> Void
    let forkAssistant: (Int) -> Void
    let content: (Int) -> AnyView

    init(chunks: [AppKitTranscriptChunk],
         chunksGeneration: UInt64? = nil,
         projectionCacheID: UUID? = nil,
         projectionRevision: UInt64? = nil,
         tailUpdate: AppKitTranscriptTailUpdate? = nil,
         workflowUpdate: AppKitTranscriptWorkflowUpdate? = nil,
         pin: TranscriptPinController,
         revealRequest: AgentBridge.TranscriptRevealRequest? = nil,
         onRevealResult: @escaping (Int, Bool) -> Void = { _, _ in },
         onPresentationSync: @escaping () -> Void = {},
         activityDetail: @escaping (Int) -> AnyView = { _ in AnyView(EmptyView()) },
         retryAssistant: @escaping (Int) -> Void = { _ in },
         forkAssistant: @escaping (Int) -> Void = { _ in },
        content: @escaping (Int) -> AnyView) {
        self.chunks = chunks
        self.chunksGeneration = chunksGeneration
        self.projectionCacheID = projectionCacheID
        self.projectionRevision = projectionRevision
        self.tailUpdate = tailUpdate
        self.workflowUpdate = workflowUpdate
        self.pin = pin
        self.revealRequest = revealRequest
        self.onRevealResult = onRevealResult
        self.onPresentationSync = onPresentationSync
        self.activityDetail = activityDetail
        self.retryAssistant = retryAssistant
        self.forkAssistant = forkAssistant
        self.content = content
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let table = NSTableView()
        table.headerView = nil
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .none
        table.allowsColumnReordering = false
        table.allowsColumnResizing = false
        table.allowsMultipleSelection = false
        table.intercellSpacing = .zero
        table.rowHeight = 44
        // Row heights come exclusively from the coordinator's measured-height cache. Combining
        // NSTableView's automatic cache with tableView(_:heightOfRow:) left two competing values
        // for the same hosted row and produced both clipped content and phantom blank space.
        table.usesAutomaticRowHeights = false

        let column = NSTableColumn(identifier: .transcript)
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.dataSource = context.coordinator
        table.delegate = context.coordinator

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.verticalScrollElasticity = .automatic
        scroll.documentView = table

        context.coordinator.attach(table: table, scrollView: scroll, pin: pin)
        context.coordinator.sync(
            chunks: chunks,
            chunksGeneration: chunksGeneration,
            projectionCacheID: projectionCacheID,
            projectionRevision: projectionRevision,
            tailUpdate: tailUpdate,
            workflowUpdate: workflowUpdate,
            content: content,
            activityDetail: activityDetail,
            retryAssistant: retryAssistant,
            forkAssistant: forkAssistant)
        onPresentationSync()
        pin.scrollView = scroll
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        if pin.scrollView !== scroll { pin.scrollView = scroll }
        context.coordinator.update(pin: pin)
        context.coordinator.sync(
            chunks: chunks,
            chunksGeneration: chunksGeneration,
            projectionCacheID: projectionCacheID,
            projectionRevision: projectionRevision,
            tailUpdate: tailUpdate,
            workflowUpdate: workflowUpdate,
            content: content,
            activityDetail: activityDetail,
            retryAssistant: retryAssistant,
            forkAssistant: forkAssistant)
        onPresentationSync()
        // After sync, so the row the request names exists. Each token is consumed once; a repeat of
        // the same token is the same request, not a new one.
        if let revealRequest {
            context.coordinator.consume(revealRequest, report: onRevealResult)
        } else {
            // No request means the find bar is closed (or was never opened). Idempotent.
            context.coordinator.clearFindHighlights()
        }
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        coordinator.removeAll()
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        weak var table: NSTableView?
        private weak var scrollView: NSScrollView?
        private weak var pin: TranscriptPinController?
        private var chunks: [AppKitTranscriptChunk] = []
        private var rows: [AppKitTranscriptPresentationRow] = []
        private var syncedProjectionCacheID: UUID?
        private var syncedProjectionRevision: UInt64?
        private var transcriptGeneration: UInt64?
        private var workflowUpdateGeneration: UInt64?
        private var assistantTailOverlay: AppKitTranscriptChunk?
        private var content: ((Int) -> AnyView)?
        private var activityDetail: ((Int) -> AnyView)?
        private var retryAssistant: ((Int) -> Void)?
        private var forkAssistant: ((Int) -> Void)?
        private var expandedActivityGroups: Set<AnyHashable> = []
        private var expandedActivityActions: Set<AnyHashable> = []
        private struct ActivityTitleCache {
            let state: AppKitActivityAction.State
            let title: String
        }
        private var activityTitles: [AnyHashable: ActivityTitleCache] = [:]
        /// Parsed/highlighted documents survive native cell recycling, but only for finalized rows
        /// in this coordinator. The cache's own count/cost bounds preserve transcript virtualization.
        private let assistantDocuments = FinalizedAssistantDocumentCache()
        var finalizedAssistantDocumentCountForTesting: Int { assistantDocuments.count }
        /// Keep one authoritative intrinsic-height cache for hosted rows and return it through the
        /// variable-height delegate API, which is the API `noteHeightOfRows` re-queries. Letting
        /// NSTableView maintain a second automatic-height cache caused clipped and phantom rows.
        private var measuredHeights: [AnyHashable: CGFloat] = [:]
        /// A transcript height is only meaningful at the column width that produced it. The table
        /// virtualizes most long conversations, so a resize leaves many rows off screen: retaining
        /// their old-width measurements or learned estimates makes each one retile as it arrives
        /// under the reader. One generation fences all callbacks and cache state to one width.
        private var heightLayoutWidth: CGFloat?
        private var heightLayoutGeneration: UInt = 0
        private var heightLayoutRetileScheduled = false
        private var tableFrameObserver: NSObjectProtocol?
        private var clipBoundsObserver: NSObjectProtocol?
        private var prefetchScheduled = false
        /// How far beyond the viewport rows are realized and measured, in viewport heights, in
        /// each direction. Bounded so a long transcript stays virtualized: this is a moving band
        /// around the reader, not the whole document.
        private static let prefetchOverdrawFactor: CGFloat = 1.5
        /// WHAT AN UNMEASURED ROW IS ASSUMED TO BE, learned per row shape.
        ///
        /// A row that has never been realized had no estimate at all: it fell back to the table's
        /// 44-point `rowHeight`, and a transcript box is hundreds of points. A long conversation
        /// opens pinned to the bottom, so EVERY row above the viewport carried 44 — and scrolling up
        /// realized them one at a time, each jumping from 44 to its real height and shoving
        /// everything below it down the screen. That is the shifting and reordering David reported:
        /// not rows changing order, but rows changing size under the ones he was reading.
        ///
        /// A running mean per shape converges after a handful of rows and turns a ten-fold error
        /// into a small one. It cannot be exact — the rows genuinely differ — but the difference
        /// between an estimate that is close and one that is 44 is the difference between settling
        /// and lurching.
        private var heightEstimates: [AppKitTranscriptHeightEstimateKey:
            AppKitTranscriptHeightEstimate] = [:]
        /// Every shape's samples pooled together, used only for a shape that has none of its own.
        ///
        /// This is what makes splitting the shape keys safe. Finer keys mean more keys that are
        /// empty on the first traversal, and an empty key used to mean the table's 44-point
        /// default — the exact ten-fold error the per-shape mean was introduced to remove. A rough
        /// cross-shape guess is wrong; 44 for a transcript box is wrong by an order of magnitude.
        private var pooledHeightEstimate = AppKitTranscriptHeightEstimate()
        private var pendingHeightIDs: Set<AnyHashable> = []
        /// NSTableView caches delegate heights for unrealized rows when it first computes the
        /// document. Learning a better shape estimate is not enough by itself: every still-
        /// unmeasured row of that shape must be explicitly invalidated or it remains 44 points
        /// until it enters the viewport and recreates the original upward-scroll lurch.
        private var pendingEstimateKeys: Set<AppKitTranscriptHeightEstimateKey> = []
        /// A row may report many exact heights while streaming or changing local disclosure state.
        /// Let each stable row train its shape estimate at most once; otherwise one live response's
        /// prefixes can consume the entire sample budget and retile every unseen historical row on
        /// each new line. The set is naturally bounded by 32 contributors per presentation shape.
        private var heightEstimateContributorIDs: Set<AnyHashable> = []
        private var heightFlushScheduled = false
        private var geometryFlushScheduled = false
        private var viewportObserver: NSObjectProtocol?
        private struct DetachedViewportAnchor {
            let rowID: AnyHashable
            /// The row's top relative to the viewport's top. Negative means the person is reading
            /// partway through a row whose beginning is already above the viewport.
            let rowTopOffset: CGFloat
        }
        private(set) var canonicalSyncCountForTesting = 0
        private(set) var exactTailSyncCountForTesting = 0
        private(set) var canonicalTailRecoveryCountForTesting = 0

        func attach(table: NSTableView,
                    scrollView: NSScrollView,
                    pin: TranscriptPinController) {
            self.table = table
            self.scrollView = scrollView
            self.pin = pin
            if let viewportObserver {
                NotificationCenter.default.removeObserver(viewportObserver)
            }
            if let tableFrameObserver {
                NotificationCenter.default.removeObserver(tableFrameObserver)
            }
            if let clipBoundsObserver {
                NotificationCenter.default.removeObserver(clipBoundsObserver)
            }
            // MEASURE ROWS BEFORE THE READER REACHES THEM.
            //
            // Everything else here corrects a row's height AFTER it has been drawn at a guess: the
            // cell is hosted, measured a runloop later, and re-tiled a runloop after that. However
            // good the guess, the correction still lands under the reader's eyes, which is what
            // reads as the cards moving around independently on the way up.
            //
            // Realizing a band of rows on either side of the viewport moves that whole sequence
            // off-screen. By the time a row is visible its height is already exact, so there is
            // nothing left to correct; the corrections that do happen are for rows nobody is
            // looking at, and the existing anchor absorbs them.
            //
            // This observes the clip view and never moves it. `TranscriptPinController` remains the
            // sole scroll authority — the rule that kept this bug class alive five times is that
            // fixes ADDED a competing scroll mechanism, and this adds none.
            scrollView.contentView.postsBoundsChangedNotifications = true
            clipBoundsObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scrollView.contentView,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.schedulePrefetch() }
            }
            scrollView.postsFrameChangedNotifications = true
            viewportObserver = NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification,
                object: scrollView,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleGeometryReconciliation() }
            }
            // The transcript has one non-resizable column, so its width follows the table's frame
            // when a window or inspector changes size. Observe that native boundary rather than a
            // SwiftUI geometry preference: the table owns row virtualization and knows precisely
            // when its cached delegate heights have become invalid.
            table.postsFrameChangedNotifications = true
            tableFrameObserver = NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification,
                object: table,
                queue: .main
            ) { [weak self, weak table] _ in
                MainActor.assumeIsolated {
                    guard let table else { return }
                    self?.synchronizeHeightLayout(for: table)
                }
            }
            heightLayoutWidth = nil
            heightLayoutGeneration &+= 1
            clearHeightCaches()
            synchronizeHeightLayout(for: table)
            scheduleGeometryReconciliation()
        }

        func update(pin: TranscriptPinController) {
            self.pin = pin
        }

        private var handledRevealToken: Int?
        private var revealReport: ((Int, Bool) -> Void)?

        private func report(_ request: AgentBridge.TranscriptRevealRequest, succeeded: Bool) {
            revealReport?(request.token, succeeded)
        }

        /// Act on a reveal request once. `updateNSView` runs for every unrelated republish of the
        /// bridge — a streamed token, a cost update — and re-scrolling to the last match on each of
        /// those would make the transcript unusable during a turn.
        ///
        /// **Detaching the pin is Find's one coupling to the scroll authority, and it is the
        /// opposite of the obvious worry.** `TranscriptPinController` treats programmatic scrolling
        /// as invisible — it detaches only on genuine user input over this scroll view — so a jump
        /// to a match cannot fight it. What it *would* do is keep following the tail: during a
        /// streaming turn the next token would yank the viewport off the match a moment after
        /// landing. Asking to see a specific row is asking to stop following, so `settle` says so
        /// through the one controller rather than adding a second follow mechanism.
        func consume(_ request: AgentBridge.TranscriptRevealRequest,
                     report: @escaping (Int, Bool) -> Void) {
            guard handledRevealToken != request.token else { return }
            handledRevealToken = request.token
            revealReport = report
            guard let row = revealRow(forSourceIndex: request.sourceIndex) else {
                self.report(request, succeeded: false)
                return
            }
            settle(row: row, request: request, passesLeft: 3)
        }

        /// Scroll, let AppKit flush, scroll again.
        ///
        /// Unrealized rows have no measurement and fall back to the default row height, so a jump
        /// into far-offscreen content lands at an estimate and then drifts as the real heights
        /// arrive. Re-scrolling on the next runloop turns corrects it. Bounded rather than looping
        /// until stable: a streaming turn changes heights continuously, and a settle that never
        /// converges would fight the transcript forever. Landing slightly off beats that.
        private func settle(row: Int,
                            request: AgentBridge.TranscriptRevealRequest,
                            passesLeft: Int) {
            guard let table else { return report(request, succeeded: false) }
            pin?.pinned = false
            table.scrollRowToVisible(row)
            guard passesLeft > 1 else {
                report(request, succeeded: highlight(row: row, request: request))
                return
            }
            let before = table.rect(ofRow: row)
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, let table = self.table else { return }
                    // Row indices shift if the transcript rebuilt underneath us; re-resolve.
                    guard let now = self.revealRow(forSourceIndex: request.sourceIndex) else {
                        self.report(request, succeeded: false)
                        return
                    }
                    guard now != row || table.rect(ofRow: now) != before else {
                        self.report(request, succeeded: self.highlight(row: now, request: request))
                        return
                    }
                    self.settle(row: now, request: request, passesLeft: passesLeft - 1)
                }
            }
        }

        /// The one match the transcript is currently showing, keyed by presentation id.
        ///
        /// The coordinator owns this rather than the cell, because `makeView` recycles cells and row
        /// views freely. State living on a cell survives into whatever row that cell is reused for:
        /// the first version of this painted the query into unrelated messages, and its row tint
        /// silently did nothing whenever the row view had not been realized yet. Holding the target
        /// here and re-applying it at every configuration point is what makes it durable.
        private var findTarget: (id: AnyHashable, query: String, occurrence: Int)?

        /// Rows that cannot mark the matched words themselves. Assistant rows paint their own text
        /// storage; `.transcript` rows are SwiftUI and build a marked `AttributedString`. What is
        /// left is headers and tool lines, where a row tint is the only thing available.
        private func rowDrawsNoOwnText(_ row: Int) -> Bool {
            guard rows.indices.contains(row) else { return false }
            switch rows[row].kind {
            case .assistant, .transcript: return false
            case .activityHeader, .activityAction: return true
            }
        }

        /// Apply the find target to a cell being configured for `row`. Called from `viewFor`, so a
        /// cell scrolled off and back gets its highlight again rather than losing it.
        private func applyFindTarget(to cell: NativeAssistantCell, row: Int) {
            guard rows.indices.contains(row), let target = findTarget, target.id == rows[row].id else {
                cell.clearFindHighlight()
                return
            }
            cell.setFindHighlight(query: target.query, occurrence: target.occurrence)
        }

        func tableView(_ tableView: NSTableView, didAdd rowView: NSTableRowView, forRow row: Int) {
            applyRowTint(rowView, row: row)
        }

        private func applyRowTint(_ rowView: NSTableRowView, row: Int) {
            let wanted = rows.indices.contains(row)
                && findTarget?.id == rows[row].id
                && rowDrawsNoOwnText(row)
            // A faint wash behind a whole row is not a find result — it does not say which words
            // matched, which is the entire question. SwiftUI rows mark the matched text themselves
            // now (see `findHighlighted`), so this only keeps a tint for rows that draw no text at
            // all, such as an activity header standing in for a collapsed tool group.
            rowView.backgroundColor = wanted ? NSColor.systemYellow.withAlphaComponent(0.18) : .clear
            rowView.needsDisplay = true
        }

        /// Repaint every realized row against the current target. Cheap — only what is on screen.
        private func refreshFindPresentation() {
            guard let table else { return }
            for row in rows.indices {
                if let rowView = table.rowView(atRow: row, makeIfNecessary: false) {
                    applyRowTint(rowView, row: row)
                }
                if let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false)
                    as? NativeAssistantCell {
                    applyFindTarget(to: cell, row: row)
                }
            }
        }

        private func highlight(row: Int, request: AgentBridge.TranscriptRevealRequest) -> Bool {
            guard rows.indices.contains(row) else { return false }
            findTarget = (rows[row].id, request.query, request.occurrenceInEntry)
            refreshFindPresentation()
            return true
        }

        /// Drop the find highlight everywhere. Called when the find bar closes — a mark left on the
        /// transcript after ⌘F is dismissed is a stain with nothing on screen explaining it.
        func clearFindHighlights() {
            guard findTarget != nil else { return }
            findTarget = nil
            refreshFindPresentation()
        }

        /// The row showing `sourceIndex`, expanding a collapsed activity group when the entry is a
        /// tool action inside one — reveal cannot scroll to a row that does not exist yet.
        ///
        /// `nil` is a real, expected answer rather than an error. The rendered list is a projection
        /// of the entries: consecutive groupable tool entries collapse, subsumed compaction chunks
        /// are not rendered at all, and provisional entries never appear. A match can therefore name
        /// text that exists in the conversation and has no row today, and the find bar steps past it
        /// rather than appearing to hang on a match it cannot show.
        private func revealRow(forSourceIndex sourceIndex: Int) -> Int? {
            if let row = rowIndex(forSourceIndex: sourceIndex) { return row }
            guard let group = chunks.compactMap(\.activityGroup).first(where: {
                $0.actions.contains { $0.sourceIndex == sourceIndex }
            }) else { return nil }
            expandedActivityGroups.insert(group.id)
            applyPresentationRows(presentationRows(for: chunks))
            return rowIndex(forSourceIndex: sourceIndex)
        }

        private func rowIndex(forSourceIndex sourceIndex: Int) -> Int? {
            rows.firstIndex { row in
                switch row.kind {
                case .transcript(let index, _, _), .assistant(let index, _):
                    return index == sourceIndex
                case .activityAction(_, let action, _, _, _):
                    return action.sourceIndex == sourceIndex
                case .activityHeader:
                    return false
                }
            }
        }

        func sync(chunks next: [AppKitTranscriptChunk],
                  chunksGeneration nextChunksGeneration: UInt64? = nil,
                  projectionCacheID nextProjectionCacheID: UUID? = nil,
                  projectionRevision nextProjectionRevision: UInt64? = nil,
                  tailUpdate nextTailUpdate: AppKitTranscriptTailUpdate? = nil,
                  workflowUpdate nextWorkflowUpdate: AppKitTranscriptWorkflowUpdate? = nil,
                  content nextContent: @escaping (Int) -> AnyView,
                  activityDetail nextActivityDetail: @escaping (Int) -> AnyView = { _ in AnyView(EmptyView()) },
                  retryAssistant nextRetryAssistant: @escaping (Int) -> Void = { _ in },
                  forkAssistant nextForkAssistant: @escaping (Int) -> Void = { _ in }) {
            guard table != nil else { return }
            content = nextContent
            activityDetail = nextActivityDetail
            retryAssistant = nextRetryAssistant
            forkAssistant = nextForkAssistant

            // Legacy/direct tests do not supply a projection revision and retain the ordinary full
            // synchronization contract. ContentView supplies one stable revision while only the
            // assistant tail grows, allowing that hot path to bypass every whole-array operation.
            if let nextProjectionRevision, let nextChunksGeneration {
                if syncedProjectionCacheID != nextProjectionCacheID
                    || syncedProjectionRevision != nextProjectionRevision {
                    assistantTailOverlay = nil
                    pruneActivityState(for: next)
                    chunks = next
                    applyPresentationRows(presentationRows(for: next))
                    syncedProjectionCacheID = nextProjectionCacheID
                    syncedProjectionRevision = nextProjectionRevision
                    transcriptGeneration = nextChunksGeneration
                    workflowUpdateGeneration = nil
                    canonicalSyncCountForTesting += 1
                }
                if let nextWorkflowUpdate,
                   workflowUpdateGeneration != nextWorkflowUpdate.generation {
                    applyWorkflowUpdate(nextWorkflowUpdate)
                }
                if let nextTailUpdate,
                   transcriptGeneration != nextTailUpdate.generation {
                    applyTailUpdate(nextTailUpdate)
                }
                return
            }

            syncedProjectionCacheID = nil
            syncedProjectionRevision = nil
            transcriptGeneration = nil
            workflowUpdateGeneration = nil
            assistantTailOverlay = nil
            pruneActivityState(for: next)
            chunks = next
            applyPresentationRows(presentationRows(for: next))
        }

        private func applyWorkflowUpdate(_ update: AppKitTranscriptWorkflowUpdate) {
            guard let table else { return }
            var changedRows = IndexSet()
            for next in update.chunks {
                guard let chunkIndex = chunks.firstIndex(where: { $0.id == next.id }),
                      let row = rows.firstIndex(where: { $0.id == next.id }) else { continue }
                chunks[chunkIndex] = next
                let presentation = AppKitTranscriptPresentationRow(
                    id: next.id,
                    revision: next.revision,
                    kind: .transcript(
                        sourceIndex: next.sourceIndex,
                        estimateClass: next.hostedHeightEstimateClass,
                        contentMetric: next.contentMetric))
                guard !rows[row].hasSameCellConfiguration(as: presentation) else { continue }
                rows[row] = presentation
                changedRows.insert(row)
            }
            workflowUpdateGeneration = update.generation
            guard !changedRows.isEmpty else { return }
            table.reloadData(
                forRowIndexes: changedRows,
                columnIndexes: IndexSet(integer: 0))
            scheduleGeometryReconciliation()
        }

        private func applyTailUpdate(_ update: AppKitTranscriptTailUpdate) {
            guard let table,
                  let baseTail = chunks.last,
                  baseTail.id == update.chunk.id,
                  let suppliedContent = update.chunk.assistant,
                  let row = rows.firstIndex(where: { $0.id == update.chunk.id }) else { return }

            let usesExactAppend = transcriptGeneration == update.append.baseGeneration
                && update.append.generation == update.generation
                && update.append.resultingUTF8Count == suppliedContent.text.utf8.count
            let content = usesExactAppend ? suppliedContent : suppliedContent.withoutTailAppend()
            let effectiveChunk = AppKitTranscriptChunk(
                id: update.chunk.id,
                revision: update.chunk.revision,
                sourceIndex: update.chunk.sourceIndex,
                hostedHeightEstimateClass: update.chunk.hostedHeightEstimateClass,
                assistant: content)
            assistantTailOverlay = effectiveChunk
            rows[row] = AppKitTranscriptPresentationRow(
                id: effectiveChunk.id,
                revision: effectiveChunk.revision,
                kind: .assistant(
                    sourceIndex: effectiveChunk.sourceIndex,
                    content: content))
            transcriptGeneration = update.generation
            if usesExactAppend {
                exactTailSyncCountForTesting += 1
            } else {
                canonicalTailRecoveryCountForTesting += 1
            }
            table.reloadData(
                forRowIndexes: IndexSet(integer: row),
                columnIndexes: IndexSet(integer: 0))
            scheduleGeometryReconciliation()
        }

        private func applyPresentationRows(_ next: [AppKitTranscriptPresentationRow]) {
            guard let table else { return }
            let currentIDs = rows.map(\.id)
            let nextIDs = next.map(\.id)
            let sameRows = currentIDs == nextIDs
            if sameRows {
                let changed = IndexSet(next.indices.filter {
                    !rows[$0].hasSameCellConfiguration(as: next[$0])
                })
                rows = next
                if !changed.isEmpty {
                    table.reloadData(forRowIndexes: changed, columnIndexes: IndexSet(integer: 0))
                    scheduleGeometryReconciliation()
                }
                return
            }

            let prefixCount = commonPrefixCount(currentIDs, nextIDs)
            let suffixCount = commonSuffixCount(currentIDs, nextIDs, after: prefixCount)
            let previousPresentation = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
            let nextLiveIDs = Set(nextIDs)
            assistantDocuments.retainOnly(nextLiveIDs)
            measuredHeights = measuredHeights.filter { nextLiveIDs.contains($0.key) }
            pendingHeightIDs = pendingHeightIDs.intersection(nextLiveIDs)

            // Inserting, removing or re-identifying a row ABOVE the reader moves every row below it
            // in document coordinates, while the clip origin stays where it was — so the viewport
            // silently lands somewhere else in the transcript. Rows above growing is why it lands
            // EARLIER, which is the "scrolling up on its own" people report (FR-341).
            //
            // Height CORRECTION already restores the reading position, in `scheduleHeightFlush`.
            // Structural change did not, and it is the more violent of the two.
            //
            // Anchor on a visible row that still exists afterwards: a row about to vanish cannot be
            // found again to measure the compensation from. This is the SAME anchor machinery
            // reporting through the same pin controller, not a second follow mechanism. Adding
            // competing scroll authorities is what made this bug class recur five times.
            let vanishingRows = IndexSet(rows.indices.filter { !nextLiveIDs.contains(rows[$0].id) })
            let structuralAnchor = detachedViewportAnchor(excluding: vanishingRows)
            defer {
                if let structuralAnchor {
                    table.layoutSubtreeIfNeeded()
                    restoreDetachedViewportAnchor(structuralAnchor)
                }
            }

            if next.count > rows.count, prefixCount + suffixCount == rows.count {
                let insertedCount = next.count - rows.count
                let inserted = IndexSet(integersIn: prefixCount..<(prefixCount + insertedCount))
                rows = next
                table.insertRows(
                    at: inserted,
                    withAnimation: [])
                let changed = changedSharedRows(
                    in: next, previousPresentation: previousPresentation)
                if !changed.isEmpty {
                    table.reloadData(forRowIndexes: changed, columnIndexes: IndexSet(integer: 0))
                }
                scheduleGeometryReconciliation()
            } else if next.count < rows.count, prefixCount + suffixCount == next.count {
                let removedCount = rows.count - next.count
                let removed = IndexSet(integersIn: prefixCount..<(prefixCount + removedCount))
                rows = next
                table.removeRows(
                    at: removed,
                    withAnimation: [])
                let changed = changedSharedRows(
                    in: next, previousPresentation: previousPresentation)
                if !changed.isEmpty {
                    table.reloadData(forRowIndexes: changed, columnIndexes: IndexSet(integer: 0))
                }
                scheduleGeometryReconciliation()
            } else {
                rows = next
                table.reloadData()
                scheduleGeometryReconciliation()
            }
        }

        private func commonPrefixCount(_ lhs: [AnyHashable], _ rhs: [AnyHashable]) -> Int {
            var count = 0
            while count < min(lhs.count, rhs.count), lhs[count] == rhs[count] { count += 1 }
            return count
        }

        private func commonSuffixCount(_ lhs: [AnyHashable],
                                       _ rhs: [AnyHashable],
                                       after prefix: Int) -> Int {
            var count = 0
            let available = min(lhs.count, rhs.count) - prefix
            while count < available,
                  lhs[lhs.count - count - 1] == rhs[rhs.count - count - 1] {
                count += 1
            }
            return count
        }

        private func changedSharedRows(
            in next: [AppKitTranscriptPresentationRow],
            previousPresentation: [AnyHashable: AppKitTranscriptPresentationRow]
        ) -> IndexSet {
            IndexSet(next.indices.filter {
                guard let previous = previousPresentation[next[$0].id] else { return false }
                return !previous.hasSameCellConfiguration(as: next[$0])
            })
        }

        private func presentationRows(
            for chunks: [AppKitTranscriptChunk]
        ) -> [AppKitTranscriptPresentationRow] {
            var result: [AppKitTranscriptPresentationRow] = []
            result.reserveCapacity(chunks.count + expandedActivityActions.count)
            for projectedChunk in chunks {
                let chunk = assistantTailOverlay?.id == projectedChunk.id
                    ? (assistantTailOverlay ?? projectedChunk)
                    : projectedChunk
                if let assistant = chunk.assistant {
                    result.append(AppKitTranscriptPresentationRow(
                        id: chunk.id,
                        revision: chunk.revision,
                        kind: .assistant(sourceIndex: chunk.sourceIndex, content: assistant)))
                    continue
                }
                guard let group = chunk.activityGroup else {
                    result.append(AppKitTranscriptPresentationRow(
                        id: chunk.id,
                        revision: chunk.revision,
                        kind: .transcript(
                            sourceIndex: chunk.sourceIndex,
                            estimateClass: chunk.hostedHeightEstimateClass,
                            contentMetric: chunk.contentMetric)))
                    continue
                }

                let isExpanded = expandedActivityGroups.contains(group.id)
                var headerHasher = Hasher()
                headerHasher.combine(chunk.revision)
                headerHasher.combine(isExpanded)
                result.append(AppKitTranscriptPresentationRow(
                    id: chunk.id,
                    revision: headerHasher.finalize(),
                    kind: .activityHeader(group: group, expanded: isExpanded)))

                guard isExpanded else { continue }
                for (offset, action) in group.actions.enumerated() {
                    let isLast = offset == group.actions.count - 1
                    let showsDetail = expandedActivityActions.contains(action.id)
                    var actionHasher = Hasher()
                    actionHasher.combine(action.revision)
                    actionHasher.combine(showsDetail)
                    actionHasher.combine(isLast)
                    actionHasher.combine(group.chatScale)
                    result.append(AppKitTranscriptPresentationRow(
                        id: AnyHashable(ActivityActionPresentationID(
                            groupID: group.id, actionID: action.id)),
                        revision: actionHasher.finalize(),
                        kind: .activityAction(
                            groupID: group.id,
                            action: action,
                            expanded: showsDetail,
                            isLast: isLast,
                            chatScale: group.chatScale)))
                }
            }
            return result
        }

        /// Accept a measurement only from the cell that still represents this exact chunk revision.
        /// Cells are reused, and streaming can replace a root again before an earlier layout callback
        /// runs; both cases must be ignored rather than applying stale geometry to a different row.
        private func acceptMeasuredHeight(_ height: CGFloat,
                                          for id: AnyHashable,
                                          revision: Int,
                                          layoutGeneration: UInt) {
            guard height.isFinite, height > 0,
                  layoutGeneration == heightLayoutGeneration,
                  let row = rows.firstIndex(where: { $0.id == id }),
                  rows[row].revision == revision else { return }

            let presentation = rows[row]
            let alignedHeight = ceil(height)
            let exactHeightChanged = measuredHeights[id].map {
                abs($0 - alignedHeight) > 0.5
            } ?? true
            let mayTrainEstimate: Bool
            switch presentation.kind {
            case .assistant(_, let content):
                mayTrainEstimate = !content.isLive
            default:
                mayTrainEstimate = true
            }
            let estimateKey = presentation.estimateKey
            let shouldTrainEstimate = mayTrainEstimate
                && !heightEstimateContributorIDs.contains(id)
                && !(heightEstimates[estimateKey]?.isFull ?? false)
            guard exactHeightChanged || shouldTrainEstimate else { return }

            if exactHeightChanged {
                measuredHeights[id] = alignedHeight
                pendingHeightIDs.insert(id)
            }
            if shouldTrainEstimate {
                heightEstimateContributorIDs.insert(id)
                if learnHeightEstimate(
                    alignedHeight,
                    for: estimateKey,
                    metric: CGFloat(presentation.heightMetric)) {
                    pendingEstimateKeys.insert(estimateKey)
                }
            }
            scheduleHeightFlush()
        }

        /// Coalesce all cell measurements produced by one SwiftUI/AppKit layout pass. Retiling a row
        /// can itself lay out its cell, so caching and the half-point equality gate above also prevent
        /// a measurement → retile → measurement feedback loop.
        private func scheduleHeightFlush() {
            guard !heightFlushScheduled else { return }
            heightFlushScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.heightFlushScheduled = false
                guard let table = self.table else {
                    self.pendingHeightIDs.removeAll()
                    self.pendingEstimateKeys.removeAll()
                    return
                }

                let ids = self.pendingHeightIDs
                self.pendingHeightIDs.removeAll()
                let estimateKeys = self.pendingEstimateKeys
                self.pendingEstimateKeys.removeAll()
                let changedRows = IndexSet(self.rows.indices.filter { row in
                    let presentation = self.rows[row]
                    return ids.contains(presentation.id)
                        || (self.measuredHeights[presentation.id] == nil
                            && estimateKeys.contains(presentation.estimateKey))
                })
                guard !changedRows.isEmpty else { return }

                // Replacing an unrealized row's estimate with its actual height moves every later
                // row in document coordinates. On a long transcript that made the box under the
                // reader jump—even though its identity and order never changed. Preserve a stable
                // visible row and its exact offset while detached. During live trackpad scrolling,
                // this rebases changed document coordinates without undoing the gesture; bottom
                // following and user-motion classification still belong to TranscriptPinController.
                let detachedAnchor = self.detachedViewportAnchor(excluding: changedRows)

                // With tableView(_:heightOfRow:) implemented below, AppKit immediately re-tiles
                // these rows from measuredHeights and expands the document/scroll range.
                table.noteHeightOfRows(withIndexesChanged: changedRows)
                table.layoutSubtreeIfNeeded()
                self.reconcileDocumentGeometry()
                if let detachedAnchor {
                    self.restoreDetachedViewportAnchor(detachedAnchor)
                }
            }
        }

        /// Bring cache ownership forward to the actual native column width. This removes both
        /// exact and learned old-width values, then reloads the small visible set so it immediately
        /// trains a current-width estimate for still-virtualized rows. The existing detached-anchor
        /// path preserves reading position while that retile happens; this is not another scroll
        /// authority.
        private func synchronizeHeightLayout(for table: NSTableView) {
            let width = table.bounds.width
            guard width.isFinite, width > 0 else { return }
            guard let previousWidth = heightLayoutWidth else {
                heightLayoutWidth = width
                return
            }
            guard abs(previousWidth - width) > 0.5 else { return }

            heightLayoutWidth = width
            heightLayoutGeneration &+= 1
            clearHeightCaches()
            scheduleHeightLayoutRetile()
        }

        private func clearHeightCaches() {
            measuredHeights.removeAll()
            heightEstimates.removeAll()
            pooledHeightEstimate = AppKitTranscriptHeightEstimate()
            pendingHeightIDs.removeAll()
            pendingEstimateKeys.removeAll()
            heightEstimateContributorIDs.removeAll()
        }

        private func scheduleHeightLayoutRetile() {
            guard !heightLayoutRetileScheduled else { return }
            heightLayoutRetileScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.heightLayoutRetileScheduled = false
                guard let table = self.table, !self.rows.isEmpty else { return }

                // A width reflow necessarily changes the text position inside a row, but the row
                // itself should stay beneath the reader's eyes. The same native anchor used for
                // ordinary measurement and structural corrections handles that compensation.
                let allRows = IndexSet(integersIn: self.rows.indices)
                let detachedAnchor = self.detachedViewportAnchor(excluding: allRows)
                table.noteHeightOfRows(withIndexesChanged: allRows)
                let visible = table.rows(in: table.visibleRect)
                if visible.location != NSNotFound, visible.length > 0 {
                    let upperBound = min(visible.location + visible.length, self.rows.count)
                    let visibleRows = IndexSet(integersIn: visible.location..<upperBound)
                    table.reloadData(
                        forRowIndexes: visibleRows,
                        columnIndexes: IndexSet(integer: 0))
                }
                table.layoutSubtreeIfNeeded()
                self.reconcileDocumentGeometry()
                if let detachedAnchor {
                    self.restoreDetachedViewportAnchor(detachedAnchor)
                }
            }
        }

        /// Coalesce the many bounds changes one gesture delivers into one prefetch per runloop
        /// turn. Realizing rows is real work; doing it per scroll event would cost more than the
        /// jitter it removes.
        private func schedulePrefetch() {
            guard !prefetchScheduled else { return }
            prefetchScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.prefetchScheduled = false
                self.prefetchRowsAroundViewport()
            }
        }

        /// Ask the table to realize the band around the viewport. `prepareContent(in:)` is
        /// AppKit's own overdraw entry point and NSTableView implements it by creating the row
        /// views that rect covers — which runs each one through the ordinary measurement path and
        /// replaces its estimate with its real height while it is still off-screen.
        private func prefetchRowsAroundViewport() {
            guard let table, table.numberOfRows > 0 else { return }
            let visible = table.visibleRect
            guard visible.height > 0, visible.width > 0 else { return }
            let overdraw = visible.height * Self.prefetchOverdrawFactor
            let expanded = visible.insetBy(dx: 0, dy: -overdraw).intersection(table.bounds)
            guard !expanded.isNull, !expanded.isEmpty else { return }
            table.prepareContent(in: expanded)
        }

        private func detachedViewportAnchor(
            excluding changingRows: IndexSet
        ) -> DetachedViewportAnchor? {
            guard pin?.mayPreserveDetachedViewportAnchor == true,
                  let table,
                  let scrollView,
                  table.numberOfRows > 0 else { return nil }
            let visible = table.rows(in: table.visibleRect)
            guard visible.location != NSNotFound,
                  rows.indices.contains(visible.location) else { return nil }
            let upperBound = min(visible.location + visible.length, rows.count)
            let visibleRows = visible.location..<upperBound
            // When the row entering at the top is the row whose estimate just changed, anchoring
            // that same row preserves only its top edge while its newly discovered height pushes
            // every box below it across the viewport. Prefer an already-stable visible neighbour;
            // its document-coordinate shift is exactly the compensation that keeps what the person
            // was reading under their eyes. Falling back handles the rare all-visible-rows batch.
            let row = visibleRows.first(where: { !changingRows.contains($0) })
                ?? visible.location
            return DetachedViewportAnchor(
                rowID: rows[row].id,
                rowTopOffset: table.rect(ofRow: row).minY
                    - scrollView.contentView.bounds.minY)
        }

        private func restoreDetachedViewportAnchor(_ anchor: DetachedViewportAnchor) {
            guard pin?.mayPreserveDetachedViewportAnchor == true,
                  let table,
                  let scrollView,
                  let row = rows.firstIndex(where: { $0.id == anchor.rowID }) else { return }
            let clip = scrollView.contentView
            var proposed = clip.bounds
            proposed.origin.y = table.rect(ofRow: row).minY - anchor.rowTopOffset
            let constrained = clip.constrainBoundsRect(proposed)
            let originBefore = clip.bounds.minY
            guard abs(originBefore - constrained.minY) > 0.5 else { return }
            clip.scroll(to: constrained.origin)
            scrollView.reflectScrolledClipView(clip)
            // AppKit may apply an additional pixel/constrain adjustment during `scroll(to:)`.
            // Rebase input samples by what actually happened, never by the requested coordinate.
            let actualCompensation = clip.bounds.minY - originBefore
            pin?.nativeViewportWasCompensated(by: actualCompensation)
        }

        /// NSTableView may retain an older, taller document frame after a variable-height row
        /// shrinks. That stale frame is real scroll range even though it contains no transcript,
        /// allowing the user to scroll into an empty pane. Conversely, a row can grow entirely
        /// inside that stale frame, so no frame-change notification reaches the pin controller.
        /// Tighten the native document to the final row and explicitly publish row-geometry changes
        /// to the sole scroll authority.
        func reconcileDocumentGeometry() {
            guard let table else { return }
            table.layoutSubtreeIfNeeded()
            let contentBottom = table.numberOfRows > 0
                ? ceil(table.rect(ofRow: table.numberOfRows - 1).maxY)
                : 0
            let viewportHeight = scrollView?.contentView.bounds.height
                ?? table.enclosingScrollView?.contentView.bounds.height
                ?? 0
            let targetHeight = max(contentBottom, viewportHeight)
            if abs(table.frame.height - targetHeight) > 0.5 {
                table.setFrameSize(NSSize(width: table.frame.width, height: targetHeight))
                table.layoutSubtreeIfNeeded()
            }
            pin?.nativeDocumentGeometryChanged()
            schedulePrefetch()
        }

        private func scheduleGeometryReconciliation() {
            guard !geometryFlushScheduled else { return }
            geometryFlushScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.geometryFlushScheduled = false
                self.reconcileDocumentGeometry()
            }
        }

        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

        /// Teach one shape a measured (content size, height) pair. Returns whether the shape's
        /// answer for THIS content size moved, which is what decides if still-unmeasured rows have
        /// to be re-tiled.
        ///
        /// Updating every unseen cached row is O(n), so the documented 32-sample bound stays a real
        /// stop rather than an endless moving average. Later rows still keep their exact measured
        /// heights; they simply cannot churn the conversation-wide guess.
        private func learnHeightEstimate(
            _ height: CGFloat,
            for key: AppKitTranscriptHeightEstimateKey,
            metric: CGFloat
        ) -> Bool {
            var estimate = heightEstimates[key] ?? AppKitTranscriptHeightEstimate()
            guard !estimate.isFull else { return false }
            let before = estimate.height(for: metric)
            estimate.add(height: height, metric: metric)
            heightEstimates[key] = estimate
            // A Workflow card is excluded from the pool on purpose. It is the one shape whose
            // measurement is documented as unable to speak for any other row — an expanded run is
            // thousands of points tall — and letting it into the cross-shape fallback makes a
            // newly appended provider-status row inherit that height. That is the overshoot the
            // separate `.workflow` key was introduced to stop, and it stays stopped here.
            if key != .hosted(.workflow), !pooledHeightEstimate.isFull {
                pooledHeightEstimate.add(height: height, metric: metric)
            }
            guard let after = estimate.height(for: metric) else { return true }
            return before.map { ceil($0) != ceil(after) } ?? true
        }

        /// What an unmeasured row of this shape and content size is assumed to be: the shape's own
        /// fit first, then the pooled cross-shape fit for a shape nothing has measured yet.
        private func estimatedHeight(
            for presentation: AppKitTranscriptPresentationRow
        ) -> CGFloat? {
            let metric = CGFloat(presentation.heightMetric)
            if let height = heightEstimates[presentation.estimateKey]?.height(for: metric) {
                return height
            }
            return pooledHeightEstimate.height(for: metric)
        }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            guard rows.indices.contains(row) else { return tableView.rowHeight }
            // Measured first — it is the truth. Then what rows of this SHAPE have measured, which is
            // a far better guess than the table's single-line default for a row that has never been
            // on screen. `rowHeight` remains the answer only before anything of that shape has been
            // measured at all.
            if let measured = measuredHeights[rows[row].id] { return measured }
            if let estimate = estimatedHeight(for: rows[row]), estimate > 0 {
                return ceil(estimate)
            }
            return tableView.rowHeight
        }

        func tableView(_ tableView: NSTableView,
                       viewFor tableColumn: NSTableColumn?,
                       row: Int) -> NSView? {
            guard rows.indices.contains(row), let content else { return nil }
            let presentation = rows[row]
            let measurementGeneration = heightLayoutGeneration
            switch presentation.kind {
            case .transcript(let sourceIndex, _, _):
                let cell = (tableView.makeView(withIdentifier: .transcript, owner: self)
                            as? TranscriptHostingCell) ?? TranscriptHostingCell()
                cell.identifier = .transcript
                cell.setRoot(content(sourceIndex)
                    .environment(\.invalidateTranscriptRowHeight) { [weak cell] in
                        cell?.invalidateHostedContentHeight()
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, row == 0 ? 16 : 0)
                    // Keep row geometry independent of its position. The old final-row-only padding
                    // changed a completed chunk's intrinsic height whenever a status/new chunk was
                    // appended, which could leave AppKit displaying that former tail's stale height.
                    .padding(.bottom, 12)
                    // Selectable SwiftUI Text otherwise adopts the hosting row's finite vertical
                    // proposal as a one-line field and ellipsizes its remaining content. Keep the real
                    // column-width proposal, but require the row's full ideal vertical size.
                    .fixedSize(horizontal: false, vertical: true),
                    id: presentation.id,
                    revision: presentation.revision) { [weak self] id, revision, height in
                        self?.acceptMeasuredHeight(
                            height,
                            for: id,
                            revision: revision,
                            layoutGeneration: measurementGeneration)
                    }
                return cell

            case .assistant(let sourceIndex, let content):
                let cell = (tableView.makeView(withIdentifier: .assistant, owner: self)
                            as? NativeAssistantCell) ?? NativeAssistantCell()
                cell.identifier = .assistant
                cell.setContent(
                    content,
                    id: presentation.id,
                    revision: presentation.revision,
                    topPadding: row == 0 ? 16 : 0,
                    onRetry: { [weak self] in self?.retryAssistant?(sourceIndex) },
                    onFork: { [weak self] in self?.forkAssistant?(sourceIndex) },
                    onMeasuredHeight: { [weak self] id, revision, height in
                        self?.acceptMeasuredHeight(
                            height,
                            for: id,
                            revision: revision,
                            layoutGeneration: measurementGeneration)
                    },
                    documentCache: assistantDocuments)
                // After `setContent`, so it paints over freshly rendered text — and on every
                // configuration, so a cell scrolled off and back gets its highlight again instead of
                // losing it, and a recycled cell is cleared instead of carrying someone else's.
                applyFindTarget(to: cell, row: row)
                return cell

            case .activityHeader(let group, let expanded):
                let cell = (tableView.makeView(withIdentifier: .activityHeader, owner: self)
                            as? ActivityGroupHeaderCell) ?? ActivityGroupHeaderCell()
                cell.identifier = .activityHeader
                cell.setGroup(
                    group,
                    id: presentation.id,
                    revision: presentation.revision,
                    expanded: expanded,
                    topPadding: row == 0 ? 16 : 0,
                    onToggle: { [weak self] in self?.toggleActivityGroup(group.id) },
                    onMeasuredHeight: { [weak self] id, revision, height in
                        self?.acceptMeasuredHeight(
                            height,
                            for: id,
                            revision: revision,
                            layoutGeneration: measurementGeneration)
                    })
                return cell

            case .activityAction(_, let action, let expanded, let isLast, let chatScale):
                let cell = (tableView.makeView(withIdentifier: .activityAction, owner: self)
                            as? ActivityActionCell) ?? ActivityActionCell()
                cell.identifier = .activityAction
                cell.setAction(
                    action,
                    presentationID: presentation.id,
                    revision: presentation.revision,
                    title: title(for: action),
                    expanded: expanded,
                    isLast: isLast,
                    chatScale: chatScale,
                    existingMeasuredHeight: measuredHeights[presentation.id],
                    detail: expanded
                        ? (activityDetail?(action.sourceIndex) ?? AnyView(EmptyView())) : nil,
                    onToggle: { [weak self] in self?.toggleActivityAction(action.id) },
                    onMeasuredHeight: { [weak self] id, revision, height in
                        self?.acceptMeasuredHeight(
                            height,
                            for: id,
                            revision: revision,
                            layoutGeneration: measurementGeneration)
                    })
                return cell
            }
        }

        func removeAll() {
            heightFlushScheduled = false
            geometryFlushScheduled = false
            if let viewportObserver {
                NotificationCenter.default.removeObserver(viewportObserver)
                self.viewportObserver = nil
            }
            if let tableFrameObserver {
                NotificationCenter.default.removeObserver(tableFrameObserver)
                self.tableFrameObserver = nil
            }
            if let clipBoundsObserver {
                NotificationCenter.default.removeObserver(clipBoundsObserver)
                self.clipBoundsObserver = nil
            }
            table?.dataSource = nil
            table?.delegate = nil
            scrollView = nil
            pin = nil
            chunks.removeAll()
            rows.removeAll()
            syncedProjectionCacheID = nil
            syncedProjectionRevision = nil
            transcriptGeneration = nil
            assistantTailOverlay = nil
            content = nil
            activityDetail = nil
            retryAssistant = nil
            forkAssistant = nil
            heightLayoutWidth = nil
            heightLayoutGeneration &+= 1
            heightLayoutRetileScheduled = false
            clearHeightCaches()
            expandedActivityGroups.removeAll()
            expandedActivityActions.removeAll()
            activityTitles.removeAll()
            assistantDocuments.removeAll()
        }

        private func pruneActivityState(for rows: [AppKitTranscriptChunk]) {
            let groups = rows.compactMap(\.activityGroup)
            let groupIDs = Set(groups.map(\.id))
            let actionIDs = Set(groups.flatMap(\.actions).map(\.id))
            expandedActivityGroups.formIntersection(groupIDs)
            expandedActivityActions.formIntersection(actionIDs)
            activityTitles = activityTitles.filter { actionIDs.contains($0.key) }
        }

        private func title(for action: AppKitActivityAction) -> String {
            if let cached = activityTitles[action.id], cached.state == action.state {
                return cached.title
            }
            let title = activityActionTitle(action)
            activityTitles[action.id] = ActivityTitleCache(state: action.state, title: title)
            return title
        }

        private func toggleActivityGroup(_ id: AnyHashable) {
            if expandedActivityGroups.contains(id) {
                expandedActivityGroups.remove(id)
                if let group = chunks.compactMap(\.activityGroup).first(where: { $0.id == id }) {
                    expandedActivityActions.subtract(group.actions.map(\.id))
                }
            } else {
                expandedActivityGroups.insert(id)
            }
            applyPresentationRows(presentationRows(for: chunks))
        }

        private func toggleActivityAction(_ id: AnyHashable) {
            guard let group = chunks.compactMap(\.activityGroup)
                .first(where: { $0.actions.contains { $0.id == id } }) else { return }
            if expandedActivityActions.contains(id) {
                expandedActivityActions.remove(id)
            } else {
                // Rich results can be multi-megabyte SwiftUI trees. Keep the expanded action list
                // native and allow only one rich detail in a group at a time.
                expandedActivityActions.subtract(group.actions.map(\.id))
                expandedActivityActions.insert(id)
            }
            expandedActivityGroups.insert(group.id)
            applyPresentationRows(presentationRows(for: chunks))
        }

    }
}

@MainActor
/// Bounds one SwiftUI/AppKit intrinsic-height feedback cycle to a stable, non-clipping result.
///
/// The hosting view fills the accepted native row height. A hosted layout can therefore answer A
/// when framed at B and B when framed at A. Without a fuse, each answer retiles NSTableView and the
/// pinned transcript visibly alternates forever. A repeated A-B-A proposal locks at max(A, B) until
/// a real content or width change begins a new layout epoch.
struct TranscriptHeightCycleFuse {
    private static let tolerance: CGFloat = 0.5

    private var previousDistinctHeight: CGFloat?
    private var latestDistinctHeight: CGFloat?
    private(set) var lastReportedHeight: CGFloat?
    private(set) var lockedHeight: CGFloat?

    /// A replacement root or revision gets an independent report lifecycle.
    mutating func beginNewRoot() {
        clearCycle()
        lastReportedHeight = nil
    }

    /// Width reflow and explicit disclosure changes may legitimately produce a new height. Retain
    /// the last report only to suppress a callback when that new epoch settles at the same value.
    mutating func beginNewLayoutEpoch() {
        clearCycle()
    }

    /// Returns the next height to publish, or nil for a duplicate/suppressed cycle proposal.
    mutating func reportableHeight(for proposedHeight: CGFloat) -> CGFloat? {
        guard proposedHeight.isFinite, proposedHeight > 0 else { return nil }
        let height = ceil(proposedHeight)

        if let lockedHeight {
            // Never shrink inside the unstable epoch. Unexpected growth is safe to publish and
            // becomes the new floor; a genuine shrink arrives through an explicit epoch reset.
            guard height > lockedHeight + Self.tolerance else { return nil }
            self.lockedHeight = height
            latestDistinctHeight = height
            return recordReport(height)
        }

        // Only distinct proposals form history. A, A, B, A is still the same A-B-A cycle.
        if let latestDistinctHeight, Self.matches(height, latestDistinctHeight) {
            return nil
        }

        if let previousDistinctHeight,
           let latestDistinctHeight,
           Self.matches(height, previousDistinctHeight) {
            let safeHeight = max(previousDistinctHeight, latestDistinctHeight)
            self.previousDistinctHeight = nil
            self.latestDistinctHeight = safeHeight
            lockedHeight = safeHeight
            return recordReport(safeHeight)
        }

        previousDistinctHeight = latestDistinctHeight
        latestDistinctHeight = height
        return recordReport(height)
    }

    private mutating func recordReport(_ height: CGFloat) -> CGFloat? {
        if let lastReportedHeight, Self.matches(height, lastReportedHeight) {
            return nil
        }
        lastReportedHeight = height
        return height
    }

    private mutating func clearCycle() {
        previousDistinctHeight = nil
        latestDistinctHeight = nil
        lockedHeight = nil
    }

    private static func matches(_ lhs: CGFloat, _ rhs: CGFloat) -> Bool {
        abs(lhs - rhs) <= tolerance
    }
}

final class TranscriptHostingCell: NSTableCellView {
    private static let geometryLogger = Logger(
        subsystem: "ai.mechanician.app",
        category: "transcript-geometry")

    private let hostController = NSHostingController(rootView: AnyView(EmptyView()))
    private var host: NSView { hostController.view }
    private var representedID: AnyHashable?
    private(set) var representedRevision = 0
    private var onMeasuredHeight: ((AnyHashable, Int, CGFloat) -> Void)?
    private var measurementScheduled = false
    private var measurementPassesRemaining = 0
    private var measurementGeneration = 0
    private var heightCycleFuse = TranscriptHeightCycleFuse()
    private var lastLaidOutSize: NSSize?
    private(set) var lastMeasuredHeight: CGFloat?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        hostController.sizingOptions = [.intrinsicContentSize]
        host.translatesAutoresizingMaskIntoConstraints = true
        host.autoresizingMask = [.width, .height]
        host.frame = bounds
        // CLIP TO THE ROW. An `NSTableCellView` does not by default, and a hosted SwiftUI root whose
        // content is taller than the row AppKit tiled draws straight over its neighbours: David's
        // recording shows four rows smeared into one band with blank space above and below it,
        // which reads as the transcript coming apart rather than as one row being measured late.
        //
        // The mismatch is unavoidable for a moment — a row's true height is not known until its
        // cell has laid out, and the correction lands on the next runloop turn. Clipping is what
        // decides whether that moment looks like a row briefly showing less of itself, or like the
        // conversation overlapping itself.
        wantsLayer = true
        layer?.masksToBounds = true
        addSubview(host)
        // The hosting root always fills the native row. Height is measured independently with
        // sizeThatFits below, then fed back to NSTableView. Keeping the frame tied to the accepted
        // row height prevents a stale intrinsic host frame from clipping wrapped Markdown even when
        // the table's own cached height is already correct.
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setRoot(_ root: some View,
                 id: AnyHashable,
                 revision: Int,
                 onMeasuredHeight: @escaping (AnyHashable, Int, CGFloat) -> Void) {
        measurementGeneration += 1
        representedID = id
        representedRevision = revision
        self.onMeasuredHeight = onMeasuredHeight
        heightCycleFuse.beginNewRoot()
        // NSTableView reuses this cell for unrelated transcript entries. Without a SwiftUI
        // identity boundary, a disclosure's @State survives `rootView` replacement and the next
        // compaction row can appear expanded even though its declared default is collapsed. Keep
        // state across revisions of this row, but never carry it into another row or conversation.
        hostController.rootView = AnyView(root.id(id))
        host.invalidateIntrinsicContentSize()
        needsLayout = true
        host.needsLayout = true
        // Assigning a new hosting root commits through SwiftUI's next layout transaction. A second
        // coalesced pass catches views whose intrinsic size settles one transaction later.
        measurementPassesRemaining = 2
        scheduleMeasurement()
    }

    override func layout() {
        super.layout()
        guard bounds.width > 0 else { return }
        if host.frame != bounds {
            host.frame = bounds
        }
        let widthChanged = lastLaidOutSize.map { abs($0.width - bounds.width) > 0.5 } ?? true
        let heightChanged = lastLaidOutSize.map { abs($0.height - bounds.height) > 0.5 } ?? true
        lastLaidOutSize = bounds.size
        // Width changes can reflow Markdown even when the transcript revision is unchanged. A
        // native row-height change deserves one follow-up after the host adopts the accepted row
        // frame. Do not measure on every ordinary table layout/scroll pass; that would negate row
        // virtualization.
        guard widthChanged || heightChanged else { return }
        // Selectable Text is backed by an AppKit interaction view that can settle one transaction
        // after the hosting root accepts its new width. Invalidate the width-dependent intrinsic
        // size so the table cannot retain the old, wider row. These are finite layout follow-ups,
        // not a display timer or scroll controller.
        if widthChanged {
            heightCycleFuse.beginNewLayoutEpoch()
            host.invalidateIntrinsicContentSize()
            host.needsLayout = true
            measurementPassesRemaining = max(measurementPassesRemaining, 2)
        }
        if heightChanged {
            measurementPassesRemaining = max(measurementPassesRemaining, 1)
        }
        scheduleMeasurement()
    }

    private func scheduleMeasurement() {
        guard measurementPassesRemaining > 0, !measurementScheduled else { return }
        measurementScheduled = true
        let generation = measurementGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.measurementScheduled = false
            guard generation == self.measurementGeneration else {
                self.scheduleMeasurement()
                return
            }
            self.reportIntrinsicHeight()
            self.measurementPassesRemaining = max(0, self.measurementPassesRemaining - 1)
            self.scheduleMeasurement()
        }
    }

    /// A child SwiftUI control changed state without replacing the row's hosting root. Re-run the
    /// same bounded intrinsic-height measurement used for transcript revisions and width changes.
    func invalidateHostedContentHeight() {
        heightCycleFuse.beginNewLayoutEpoch()
        host.invalidateIntrinsicContentSize()
        host.needsLayout = true
        measurementPassesRemaining = max(measurementPassesRemaining, 2)
        scheduleMeasurement()
    }

    private func reportIntrinsicHeight() {
        guard let id = representedID, bounds.width > 0 else { return }
        updateConstraintsForSubtreeIfNeeded()
        layoutSubtreeIfNeeded()
        host.updateConstraintsForSubtreeIfNeeded()
        host.layoutSubtreeIfNeeded()
        // Do not rely on host.intrinsicContentSize here: immediately after replacing the root it can
        // still reflect the previous SwiftUI layout transaction. Ask SwiftUI directly for an
        // unconstrained height at the real column width instead.
        let proposedHeight = hostController.sizeThatFits(
            in: NSSize(width: bounds.width, height: .greatestFiniteMagnitude)).height
        lastMeasuredHeight = proposedHeight
        let wasLocked = heightCycleFuse.lockedHeight != nil
        let height = heightCycleFuse.reportableHeight(for: proposedHeight)
        if !wasLocked, let lockedHeight = heightCycleFuse.lockedHeight {
            Self.geometryLogger.error(
                "Hosted transcript height cycle stopped revision=\(self.representedRevision, privacy: .public) width=\(Int(self.bounds.width), privacy: .public) lockedHeight=\(Int(lockedHeight), privacy: .public)")
        }
        guard let height else { return }
        onMeasuredHeight?(id, representedRevision, height)
    }
}

private extension NSUserInterfaceItemIdentifier {
    static let transcript = NSUserInterfaceItemIdentifier("Mechanician.TranscriptChunk")
    static let assistant = NSUserInterfaceItemIdentifier("Mechanician.NativeAssistant")
    static let activityHeader = NSUserInterfaceItemIdentifier("Mechanician.ActivityHeader")
    static let activityAction = NSUserInterfaceItemIdentifier("Mechanician.ActivityAction")
}
