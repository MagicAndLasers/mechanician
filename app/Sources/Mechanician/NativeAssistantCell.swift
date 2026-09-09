import AppKit
import SwiftUI

/// A deliberately small, presentation-only MRU for finalized assistant documents.
///
/// The transcript table recycles cells, so revisiting a long completed response otherwise repeats
/// Markdown parsing and syntax highlighting even though the provider-owned text is immutable. The
/// cache stays with one transcript coordinator rather than the model or renderer: that keeps it out
/// of persistence, drops it with the visible conversation, and avoids sharing mutable TextKit table
/// block attributes between separate windows or unrelated rows.
@MainActor
final class FinalizedAssistantDocumentCache {
    nonisolated static let maximumEntryCount = 32
    nonisolated static let maximumEstimatedCost = 16 * 1_024 * 1_024
    nonisolated static let maximumSourceUTF8Count = 512 * 1_024
    nonisolated static let maximumDocumentLength = 512 * 1_024

    private struct Entry {
        let source: String
        let sourceUTF8Count: Int
        let scale: CGFloat
        let document: NSAttributedString
        let estimatedCost: Int
        var recency: UInt64
    }

    private let maximumEntries: Int
    private let maximumCost: Int
    private var entries: [AnyHashable: Entry] = [:]
    private var recency: UInt64 = 0
    private(set) var estimatedCost = 0

    init(
        maximumEntries: Int = FinalizedAssistantDocumentCache.maximumEntryCount,
        maximumCost: Int = FinalizedAssistantDocumentCache.maximumEstimatedCost
    ) {
        precondition(maximumEntries > 0)
        precondition(maximumCost > 0)
        self.maximumEntries = maximumEntries
        self.maximumCost = maximumCost
    }

    var count: Int { entries.count }

    /// Exact source validation is intentionally outside the dictionary key. Hashing a 300 KiB
    /// response merely to discover a cache hit would put linear work back on the row-reuse path.
    func document(
        for id: AnyHashable,
        source: String,
        scale: CGFloat
    ) -> NSAttributedString? {
        guard let entry = entries[id] else { return nil }
        guard entry.scale == scale,
              entry.sourceUTF8Count == source.utf8.count,
              entry.source == source else {
            remove(id)
            return nil
        }
        var refreshed = entry
        refreshed.recency = nextRecency()
        entries[id] = refreshed
        return entry.document
    }

    /// Admit only renderer-owned pristine output. Callers treat the returned object graph as frozen
    /// and each cell installs a private NSTextStorage copy before Find paints it. Retaining the
    /// renderer's builder avoids adding a second O(n) copy to the first realization merely to make
    /// a later reuse cheap. Paragraph/table attribute objects are still shared by Foundation, so
    /// callers additionally keep this cache row-local and coordinator-local.
    @discardableResult
    func insert(
        _ document: NSAttributedString,
        for id: AnyHashable,
        source: String,
        scale: CGFloat
    ) -> NSAttributedString {
        let sourceUTF8Count = source.utf8.count
        let documentLength = document.length
        let cost = Self.estimatedCost(
            documentLength: documentLength,
            sourceUTF8Count: sourceUTF8Count)
        remove(id)
        // An oversize document cannot produce a future hit. Return its one required render directly
        // to NSTextStorage and retain nothing.
        guard sourceUTF8Count <= Self.maximumSourceUTF8Count,
              documentLength <= Self.maximumDocumentLength,
              cost <= maximumCost else { return document }

        let stamp = nextRecency()
        entries[id] = Entry(
            source: source,
            sourceUTF8Count: sourceUTF8Count,
            scale: scale,
            document: document,
            estimatedCost: cost,
            recency: stamp)
        estimatedCost += cost
        evictToBounds()
        return document
    }

    /// Drop rows that no longer belong to this coordinator. Scale and source changes are validated
    /// lazily on lookup so ordinary streaming sync never adds another full-transcript scan.
    func retainOnly(_ liveIDs: Set<AnyHashable>) {
        let stale = entries.keys.filter { !liveIDs.contains($0) }
        stale.forEach(remove)
    }

    func removeAll() {
        entries.removeAll(keepingCapacity: false)
        estimatedCost = 0
        recency = 0
    }

    func contains(_ id: AnyHashable) -> Bool { entries[id] != nil }

    private func nextRecency() -> UInt64 {
        if recency == .max {
            let ordered = entries.sorted { $0.value.recency < $1.value.recency }
            for (offset, pair) in ordered.enumerated() {
                var entry = pair.value
                entry.recency = UInt64(offset + 1)
                entries[pair.key] = entry
            }
            recency = UInt64(ordered.count)
        }
        recency += 1
        return recency
    }

    private func remove(_ id: AnyHashable) {
        guard let removed = entries.removeValue(forKey: id) else { return }
        estimatedCost -= removed.estimatedCost
    }

    private func evictToBounds() {
        while entries.count > maximumEntries || estimatedCost > maximumCost {
            guard let oldest = entries.min(by: { $0.value.recency < $1.value.recency })?.key
            else { break }
            remove(oldest)
        }
    }

    /// A deterministic weighted retained-size proxy, not an RSS claim. Charging 32 bytes per
    /// rendered UTF-16 unit covers text plus dense run/attribute objects without walking every
    /// attribute on first realization; source is charged separately because exact identity and
    /// code-block metadata can retain it. Independent per-dimension caps reject pathological
    /// source-heavy or expansion-heavy documents even when the weighted total would fit.
    private static func estimatedCost(
        documentLength: Int,
        sourceUTF8Count: Int
    ) -> Int {
        return saturatingAdd(
            4 * 1_024,
            saturatingAdd(
                saturatingMultiply(sourceUTF8Count, 2),
                saturatingMultiply(documentLength, 32)))
    }

    private static func saturatingMultiply(_ lhs: Int, _ rhs: Int) -> Int {
        let (result, overflow) = lhs.multipliedReportingOverflow(by: rhs)
        return overflow ? .max : result
    }

    private static func saturatingAdd(_ lhs: Int, _ rhs: Int) -> Int {
        let (result, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? .max : result
    }
}

/// Incremental presentation state for one append-only live Markdown response.
///
/// `TranscriptEntry.text` remains the only source of truth. This value retains only the mutable
/// source suffix plus the rendered length of prefixes already installed in TextKit. A blank line
/// outside a fence, or a closed fence followed by more content, makes the preceding source stable
/// under `MarkdownText`'s grammar. Those prefixes render once; later deltas replace only the
/// mutable TextKit suffix. Any replacement, scale change, row reuse, or terminal transition drops
/// this value and takes the canonical full-render path.
@MainActor
struct NativeMarkdownIncrementalDocument {
    struct Update {
        let replacementStart: Int
        let replacement: NSAttributedString
        let stableRenderedLength: Int
    }

    private(set) var sourceUTF8Count = 0
    private(set) var mutableSource = ""
    private(set) var stableRenderedLength = 0
    /// Used only by the full-source convenience API and its differential tests. The live cell uses
    /// exact append metadata and therefore does not retain a second copy of the accumulated source.
    private var validationSource: String?

    mutating func update(source nextSource: String, scale: CGFloat) -> Update? {
        guard let previous = validationSource else {
            let update = reset(source: nextSource, scale: scale)
            validationSource = nextSource
            return update
        }
        guard nextSource.hasPrefix(previous) else { return nil }
        let appended = String(nextSource.dropFirst(previous.count))
        let update = update(
            appending: appended,
            baseUTF8Count: previous.utf8.count,
            resultingUTF8Count: nextSource.utf8.count,
            scale: scale)
        if update != nil { validationSource = nextSource }
        return update
    }

    mutating func reset(source: String, scale: CGFloat) -> Update {
        sourceUTF8Count = 0
        mutableSource = ""
        stableRenderedLength = 0
        validationSource = nil
        // Zero is the exact base of a reset, so this cannot fail.
        return update(
            appending: source,
            baseUTF8Count: 0,
            resultingUTF8Count: source.utf8.count,
            scale: scale)!
    }

    mutating func update(
        appending appended: String,
        baseUTF8Count: Int,
        resultingUTF8Count: Int,
        scale: CGFloat
    ) -> Update? {
        guard baseUTF8Count == sourceUTF8Count,
              resultingUTF8Count >= baseUTF8Count,
              appended.utf8.count == resultingUTF8Count - baseUTF8Count else { return nil }
        let combinedMutable = mutableSource + appended
        var sealedSource = ""
        var nextMutable = combinedMutable
        if let cutoff = Self.stablePrefixEnd(in: combinedMutable) {
            let candidate = String(combinedMutable[..<cutoff])
            let suffix = String(combinedMutable[cutoff...])
            // Empty fenced blocks and leading blank lines produce no canonical block. Sealing them
            // would install NativeMarkdownRenderer's empty-document placeholder into real output.
            // Keep the prefix mutable until the suffix produces a block too: an incomplete opening
            // fence is deliberately omitted by the canonical parser, so adding the inter-block
            // separator before that fence becomes renderable would briefly diverge from truth.
            if !MarkdownText.blocks(from: candidate).isEmpty,
               !MarkdownText.blocks(from: suffix).isEmpty {
                sealedSource = candidate
                nextMutable = suffix
            }
        }

        let replacement = NSMutableAttributedString()
        var sealedRenderedLength = 0
        if !sealedSource.isEmpty {
            let sealed = NativeMarkdownRenderer.render(
                sealedSource,
                scale: scale,
                followedByMoreBlocks: true)
            sealedRenderedLength = sealed.length
            replacement.append(sealed)
        }
        let mutable = NativeMarkdownRenderer.render(nextMutable, scale: scale)
        replacement.append(mutable)

        let replacementStart = stableRenderedLength
        stableRenderedLength += sealedRenderedLength
        sourceUTF8Count = resultingUTF8Count
        mutableSource = nextMutable
        return Update(
            replacementStart: replacementStart,
            replacement: replacement,
            stableRenderedLength: stableRenderedLength)
    }

    /// Conservative source boundaries only. A single trailing newline is deliberately not stable:
    /// the next append can continue that paragraph. Blank lines outside code and a closed fence are
    /// stable only when non-whitespace content already follows them, which also preserves the full
    /// renderer's final-block paragraph spacing.
    private static func stablePrefixEnd(in source: String) -> String.Index? {
        var candidates: [String.Index] = []
        var inCode = false
        var lineStart = source.startIndex

        while lineStart < source.endIndex,
              let newline = source[lineStart...].firstIndex(of: "\n") {
            let line = source[lineStart..<newline]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let afterNewline = source.index(after: newline)
            if trimmed.hasPrefix("```") {
                let wasInCode = inCode
                inCode.toggle()
                if wasInCode { candidates.append(afterNewline) }
            } else if !inCode, trimmed.isEmpty {
                candidates.append(afterNewline)
            }
            lineStart = afterNewline
        }

        return candidates.reversed().first { candidate in
            source[candidate...].contains { !$0.isWhitespace }
        }
    }
}

/// Native TextKit presentation for assistant prose. Streaming text used to replace a SwiftUI
/// hosting root and settle through multiple asynchronous intrinsic-size passes, which made the
/// pinned transcript visibly jump. This cell parses, lays out, and measures one authoritative
/// TextKit document synchronously at the table column's real width.
@MainActor
final class NativeAssistantCell: NSTableCellView, NSTextViewDelegate {
    private let bubble = NativeAssistantBubbleView()
    /// One shared copy button that follows the pointer to whichever fenced code block it is over.
    /// A button per block would mean N subviews to create, position and tear down on every relayout
    /// of a streaming cell; the pointer can only be over one block at a time.
    private lazy var codeCopyButton: HoverActionButton = {
        // Same idiom as the row's Copy/Retry/Fork actions — borderless SF Symbol, secondary tint,
        // resting alpha — rather than a stock Aqua push button, which read as a foreign control
        // pasted onto a dark transcript.
        let button = NativeAssistantCell.makeActionButton(symbol: "doc.on.doc", label: "Copy code")
        button.target = self
        button.action = #selector(copyHoveredCode)
        button.alphaValue = NativeAssistantCell.restActionAlpha
        button.onHoverChange = { [weak button] hovering in
            guard let button else { return }
            button.contentTintColor = hovering ? .labelColor : .secondaryLabelColor
            button.alphaValue = hovering ? 1 : NativeAssistantCell.restActionAlpha
        }
        button.isHidden = true
        return button
    }()
    /// Source of the block currently under the pointer, and its rect in text-view coordinates.
    private var hoveredCode: (source: String, rect: NSRect)?
    private var codeTracking: NSTrackingArea?
    private let textView: NSTextView
    private let eyebrowLabel = NSTextField(labelWithString: "")
    private let copyButton = NativeAssistantCell.makeActionButton(
        symbol: "doc.on.doc", label: "Copy")
    private let retryButton = NativeAssistantCell.makeActionButton(
        symbol: "arrow.clockwise", label: "Retry")
    private let forkButton = NativeAssistantCell.makeActionButton(
        symbol: "arrow.triangle.branch", label: "Fork")
    /// How the answer turned out, recorded against every remembered statement it was given.
    ///
    /// Sits with Copy and Retry because it judges the ANSWER, which
    /// is the thing the person actually formed an opinion about. A verdict per statement asks them
    /// to attribute credit among ten sentences they did not read individually.

    private var representedID: AnyHashable?
    private(set) var representedRevision = 0
    private var content: AppKitAssistantContent?
    private var onRetry: (() -> Void)?
    private var onFork: (() -> Void)?
    private var onMeasuredHeight: ((AnyHashable, Int, CGFloat) -> Void)?
    private var lastLayoutWidth: CGFloat?
    private var lastReportedHeight: CGFloat?
    private(set) var markdownRenderCountForTesting = 0
    private(set) var canonicalMarkdownRenderCountForTesting = 0
    /// Markdown can become temporarily shorter when an append completes syntax such as a code
    /// fence. The provider still only appended text, so publishing that transient shrink makes a
    /// pinned transcript jump backward before the next delta grows it again. Preserve the largest
    /// TextKit height across append-only revisions at one width; reset for replacement content,
    /// another response, a scale change, or a genuine width reflow.
    private var appendOnlyTextHeightFloor: CGFloat?
    private var lastRenderedText: String?
    private var lastRenderedUTF8Count: Int?
    private var lastRenderedScale: CGFloat?
    private var lastRenderedTranscriptGeneration: UInt64?
    private var lastRenderedWasLive = false
    private var incrementalMarkdown: NativeMarkdownIncrementalDocument?

    /// FR-98/FR-99: message actions recede at rest so they don't add noise to every row; only the
    /// control under the pointer brightens (per-button hover), and a click briefly confirms.
    private static let restActionAlpha: CGFloat = 0.4
    private var confirmResets: [HoverActionButton: DispatchWorkItem] = [:]

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(containerSize: NSSize(
            width: 1, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = false
        container.heightTracksTextView = false
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
        textView = NSTextView(frame: .zero, textContainer: container)

        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true

        bubble.addSubview(eyebrowLabel)
        bubble.addSubview(textView)
        bubble.addSubview(codeCopyButton)
        addSubview(bubble)
        for button in [copyButton, retryButton, forkButton] {
            addSubview(button)
            button.alphaValue = Self.restActionAlpha
            button.onHoverChange = { [weak self, weak button] hovering in
                guard let self, let button else { return }
                self.setButtonHovered(button, hovering)
            }
        }

        textView.delegate = self
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.isRichText = true
        textView.importsGraphics = false
        textView.textContainerInset = .zero
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = []
        textView.linkTextAttributes = [
            .foregroundColor: NSColor.nInfoText,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ]
        eyebrowLabel.isEditable = false
        eyebrowLabel.isSelectable = false
        eyebrowLabel.drawsBackground = false
        eyebrowLabel.isBezeled = false
        eyebrowLabel.lineBreakMode = .byTruncatingTail
        eyebrowLabel.textColor = .nInfoText
        eyebrowLabel.setAccessibilityRole(.staticText)

        copyButton.target = self
        copyButton.action = #selector(copyResponse)
        retryButton.target = self
        retryButton.action = #selector(retryResponse)
        forkButton.target = self
        forkButton.action = #selector(forkResponse)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setContent(
        _ content: AppKitAssistantContent,
        id: AnyHashable,
        revision: Int,
        topPadding: CGFloat,
        onRetry: @escaping () -> Void,
        onFork: @escaping () -> Void,
        onMeasuredHeight: @escaping (AnyHashable, Int, CGFloat) -> Void,
        documentCache: FinalizedAssistantDocumentCache? = nil
    ) {
        let sameResponse = representedID == id
        // Scale is part of the rendered-document identity. It is currently stepped in exact 0.1
        // increments; an approximate match could leave stale font attributes if that input ever
        // becomes animated or otherwise fractional.
        let sameScale = lastRenderedScale == content.chatScale
        let exactTailAppend = sameResponse && sameScale && content.tailAppend.map { append in
            lastRenderedTranscriptGeneration == append.baseGeneration
                && content.transcriptGeneration == append.generation
                && lastRenderedUTF8Count == append.baseUTF8Count
                && append.resultingUTF8Count >= append.baseUTF8Count
                && append.delta.utf8.count
                    == append.resultingUTF8Count - append.baseUTF8Count
        } == true
        let sameText = !exactTailAppend && sameResponse && lastRenderedText.map { previous in
            lastRenderedUTF8Count == content.text.utf8.count && previous == content.text
        } == true
        // Exact generation metadata owns the incremental TextKit fast path, but it is not required
        // to recognize the older/full-projection fallback as append-only for geometry. A newly
        // attached or temporarily lagging coordinator can legitimately supply canonical text with
        // no descriptor; dropping the height floor there lets a partially typed Markdown fence
        // shrink the row and visibly pulls a bottom-pinned transcript backward.
        let canonicalPrefixAppend = sameResponse && sameScale && lastRenderedText.map { previous in
            content.text.count > previous.count && content.text.hasPrefix(previous)
        } == true
        let appendOnly = sameText || exactTailAppend || canonicalPrefixAppend
        if !appendOnly || !sameScale {
            appendOnlyTextHeightFloor = nil
        }
        // Revisions also carry presentation-only state (live actions and Find). Those controls and
        // highlights update below without replacing an identical TextKit document. A live row's
        // terminal transition is the exception: reconcile once through the canonical renderer and
        // admit that pristine result immediately, even when its source did not change.
        let sealsLiveDocument = sameResponse && lastRenderedWasLive && !content.isLive
        let mustRender = !sameText || !sameScale || sealsLiveDocument
        // A recycled cell must not carry the previous row's find highlight into new content. The
        // coordinator re-applies it straight after this call for the row that actually owns it.
        if !sameResponse { findHighlight = nil; savedHighlightAttributes = [] }
        representedID = id
        representedRevision = revision
        self.content = content
        self.onRetry = onRetry
        self.onFork = onFork
        self.onMeasuredHeight = onMeasuredHeight
        bubble.topPadding = topPadding
        bubble.isReview = content.isReview
        eyebrowLabel.stringValue = content.eyebrow ?? ""
        eyebrowLabel.isHidden = content.eyebrow == nil
        eyebrowLabel.font = .systemFont(ofSize: 10.5 * content.chatScale, weight: .semibold)
        eyebrowLabel.setAccessibilityLabel(content.eyebrow ?? "")
        retryButton.isHidden = content.isLive || !content.canRetry
        copyButton.isHidden = content.isLive
        forkButton.isHidden = content.isLive || !content.canFork
        restoreActionButtons()

        if mustRender {
            // Rows are recycled and streamed content re-lays out constantly; a button still parked
            // over the previous block's rect would copy the wrong thing.
            hideCodeCopyButton()
            removeFindHighlightPaint()
            let rendered: NSAttributedString
            if content.isLive {
                markdownRenderCountForTesting += 1
                var incremental: NativeMarkdownIncrementalDocument
                var update: NativeMarkdownIncrementalDocument.Update
                if exactTailAppend,
                   var existing = incrementalMarkdown,
                   let append = content.tailAppend,
                   let appended = existing.update(
                       appending: append.delta,
                       baseUTF8Count: append.baseUTF8Count,
                       resultingUTF8Count: append.resultingUTF8Count,
                       scale: content.chatScale) {
                    incremental = existing
                    update = appended
                } else {
                    incremental = NativeMarkdownIncrementalDocument()
                    update = incremental.reset(
                        source: content.text,
                        scale: content.chatScale)
                    canonicalMarkdownRenderCountForTesting += 1
                }
                if let storage = textView.textStorage,
                   update.replacementStart <= storage.length {
                    replaceRenderedSuffix(
                        in: storage,
                        from: update.replacementStart,
                        with: update.replacement)
                    incrementalMarkdown = incremental
                    rendered = storage
                } else {
                    // A recycled or externally-mutated TextKit document is not a reason to trust an
                    // incremental range. Replace it from the freshly reset canonical source.
                    incremental = NativeMarkdownIncrementalDocument()
                    update = incremental.reset(
                        source: content.text,
                        scale: content.chatScale)
                    canonicalMarkdownRenderCountForTesting += 1
                    incrementalMarkdown = incremental
                    rendered = update.replacement
                }
            } else if !content.isLive,
               let cached = documentCache?.document(
                   for: id,
                   source: content.text,
                   scale: content.chatScale
               ) {
                incrementalMarkdown = nil
                rendered = cached
            } else {
                incrementalMarkdown = nil
                markdownRenderCountForTesting += 1
                canonicalMarkdownRenderCountForTesting += 1
                let fresh = NativeMarkdownRenderer.render(
                    content.text,
                    scale: content.chatScale)
                rendered = content.isLive
                    ? fresh
                    : (documentCache?.insert(
                        fresh,
                        for: id,
                        source: content.text,
                        scale: content.chatScale) ?? fresh)
            }
            if rendered !== textView.textStorage {
                textView.textStorage?.setAttributedString(rendered)
            }
            lastRenderedText = content.text
            lastRenderedUTF8Count = content.tailAppend?.resultingUTF8Count
                ?? content.text.utf8.count
            lastRenderedScale = content.chatScale
            lastRenderedTranscriptGeneration = content.transcriptGeneration
            // Re-render replaces the whole text storage, which takes the find highlight with it.
            // The cell owns the highlight rather than the caller for exactly this reason: a
            // streaming turn re-renders continuously, and a highlight applied once from outside
            // would vanish on the next token.
            applyFindHighlight()
        }
        lastRenderedWasLive = content.isLive
        lastReportedHeight = nil
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    override func layout() {
        super.layout()
        guard let content, let id = representedID, bounds.width > 32 else { return }

        let outerX: CGFloat = 16
        let top = bubble.topPadding
        let bubbleWidth = max(1, bounds.width - outerX * 2)
        let textWidth = max(1, bubbleWidth - 20)
        if lastLayoutWidth.map({ abs($0 - textWidth) > 0.5 }) ?? true {
            lastLayoutWidth = textWidth
            appendOnlyTextHeightFloor = nil
            // TextKit reflows blocks at the new width without moving the pointer. The shared copy
            // button's old frame and cached source no longer describe what is beneath it, so make
            // the next pointer movement resolve the block again.
            hideCodeCopyButton()
            textView.textContainer?.containerSize = NSSize(
                width: textWidth, height: .greatestFiniteMagnitude)
        }

        let measuredTextHeight = measuredTextHeight(width: textWidth)
        let textHeight = max(measuredTextHeight, appendOnlyTextHeightFloor ?? 0)
        appendOnlyTextHeightFloor = textHeight
        let eyebrowHeight: CGFloat = content.eyebrow == nil ? 0 : ceil(18 * content.chatScale)
        let bubbleHeight = max(20, ceil(textHeight) + eyebrowHeight + 20)
        bubble.frame = NSRect(x: outerX, y: top, width: bubbleWidth, height: bubbleHeight)
        if content.eyebrow != nil {
            eyebrowLabel.frame = NSRect(x: 10, y: 8, width: textWidth, height: eyebrowHeight)
        } else {
            eyebrowLabel.frame = .zero
        }
        textView.frame = NSRect(
            x: 10,
            y: 10 + eyebrowHeight,
            width: textWidth,
            height: ceil(textHeight))

        let showsActions = !content.isLive
        // Reserve the completed-message action lane while the answer is still live. AppKit can
        // settle a row-height change separately from its content reload; if terminalization also
        // grows the row, that interval paints Copy/Retry/Fork below the cell's clipping boundary.
        // Keeping the lane in both states makes terminalization a visibility change only.
        let actionHeight: CGFloat = 25
        if showsActions {
            var x = outerX + 2
            for button in [copyButton, retryButton, forkButton]
                where !button.isHidden {
                button.frame = NSRect(x: x, y: bubble.frame.maxY + 3, width: 24, height: 22)
                // NSTableView reuses and moves cells while the pointer can remain stationary.
                // AppKit does not guarantee a matching mouseExited when a tracked view moves out
                // from under that pointer, so reconcile against the button's new frame now.
                button.reconcileHoverState()
                x += 26
            }
        }
        let measured = top + bubbleHeight + actionHeight + 12
        if lastReportedHeight.map({ abs($0 - measured) > 0.5 }) ?? true {
            lastReportedHeight = measured
            onMeasuredHeight?(id, representedRevision, measured)
        }
    }

    private func measuredTextHeight(width: CGFloat) -> CGFloat {
        guard let container = textView.textContainer,
              let layoutManager = textView.layoutManager else { return 1 }
        container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: container)
        return max(1, layoutManager.usedRect(for: container).height)
    }

    /// Replace only the mutable rendered tail and preserve selections that belong wholly to the
    /// stable prefix. TextKit uses UTF-16 ranges, which is also the unit carried by attributed-
    /// string lengths and the incremental document's replacement boundary.
    private func replaceRenderedSuffix(
        in storage: NSTextStorage,
        from replacementStart: Int,
        with replacement: NSAttributedString
    ) {
        let oldLength = storage.length
        let start = min(max(0, replacementStart), oldLength)
        let replaced = NSRange(location: start, length: oldLength - start)
        let selections = textView.selectedRanges.compactMap { $0.rangeValue }

        storage.beginEditing()
        storage.replaceCharacters(in: replaced, with: replacement)
        storage.endEditing()

        let newLength = storage.length
        let delta = replacement.length - replaced.length
        textView.selectedRanges = selections.map { selection in
            let adjusted: NSRange
            if NSMaxRange(selection) <= start {
                adjusted = selection
            } else if selection.location >= NSMaxRange(replaced) {
                adjusted = NSRange(
                    location: max(0, selection.location + delta),
                    length: selection.length)
            } else {
                adjusted = NSRange(
                    location: min(newLength, start + replacement.length),
                    length: 0)
            }
            return NSValue(range: adjusted)
        }
    }

    @objc private func copyResponse() {
        guard let text = content?.text else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        confirmClick(on: copyButton)
    }

    @objc private func retryResponse() { confirmClick(on: retryButton); onRetry?() }
    @objc private func forkResponse() { confirmClick(on: forkButton); onFork?() }

    // MARK: FR-98/FR-99 — quiet-at-rest actions; only the hovered control brightens; confirm on click

    /// Raise only the control under the pointer (FR-99), not the whole cluster. A button that is
    /// mid-confirmation owns its own look until its timer settles.
    private func setButtonHovered(_ button: HoverActionButton, _ hovered: Bool) {
        guard confirmResets[button] == nil else { return }
        button.contentTintColor = hovered ? .labelColor : .secondaryLabelColor
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            button.animator().alphaValue = hovered ? 1 : Self.restActionAlpha
        }
    }

    /// Swap the clicked control to a green checkmark for ~1s so the action is unmistakable, then
    /// settle back to its resting glyph and hover-appropriate opacity on its own.
    private func confirmClick(on button: HoverActionButton) {
        confirmResets[button]?.cancel()
        let restoreImage = button.image
        button.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: "Done")
        button.contentTintColor = .nSuccessText
        button.alphaValue = 1
        let reset = DispatchWorkItem { [weak self, weak button] in
            guard let self, let button else { return }
            button.image = restoreImage
            button.contentTintColor = button.isHovering ? .labelColor : .secondaryLabelColor
            self.confirmResets[button] = nil
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                button.animator().alphaValue = button.isHovering ? 1 : Self.restActionAlpha
            }
        }
        confirmResets[button] = reset
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.95, execute: reset)
    }

    /// Cancel any pending confirmation and return the actions to their resting look — called on
    /// cell reuse so a checkmark can't linger onto a different response.
    private func restoreActionButtons() {
        confirmResets.values.forEach { $0.cancel() }
        confirmResets.removeAll()
        copyButton.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy")
        retryButton.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Retry")
        forkButton.image = NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: "Fork")
        for button in [copyButton, retryButton, forkButton] {
            button.contentTintColor = button.isHovering ? .labelColor : .secondaryLabelColor
            button.alphaValue = button.isHovering ? 1 : Self.restActionAlpha
        }
    }

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        guard let url = Self.linkURL(from: link) else { return false }
        // Local/path links open in-app; web + custom-scheme links go to the system. The AppKit
        // delegate can't consume SwiftUI's `.systemAction`, so non-local links are opened here
        // directly (previously they were swallowed and nothing happened).
        if !TranscriptLinkHandler.handleLocal(url, relativeTo: content?.cwd ?? "") {
            NSWorkspace.shared.open(url)
        }
        return true
    }

    func textView(
        _ textView: NSTextView,
        menu: NSMenu,
        for event: NSEvent,
        at charIndex: Int
    ) -> NSMenu? {
        guard charIndex >= 0,
              charIndex < (textView.textStorage?.length ?? 0),
              let link = textView.textStorage?.attribute(
                  .link,
                  at: charIndex,
                  effectiveRange: nil),
              let url = Self.linkURL(from: link) else {
            return menu
        }
        return TranscriptLinkHandler.contextMenu(
            for: url,
            relativeTo: content?.cwd ?? "") ?? menu
    }

    private static func linkURL(from link: Any) -> URL? {
        if let value = link as? URL { return value }
        if let value = link as? String { return URL(string: value) }
        return nil
    }

    private static func makeActionButton(symbol: String, label: String) -> HoverActionButton {
        let button = HoverActionButton()
        button.isBordered = false
        button.bezelStyle = .inline
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.imagePosition = .imageOnly
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = label
        button.setAccessibilityLabel(label)
        return button
    }
    /// The cell needs its OWN tracking area: `mouseMoved` is only delivered to the owner of an area
    /// that asked for it, and the row has none by default. Without this the code-block copy button
    /// can never appear, because nothing ever reports where the pointer is.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let codeTracking { removeTrackingArea(codeTracking) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil)
        addTrackingArea(area)
        codeTracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        updateCodeCopyButton(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        hideCodeCopyButton()
    }

    /// Find the fenced code block under `point` (cell coordinates) and park the copy button at its
    /// top-right. Returns the block to nothing when the pointer is over prose.
    private func updateCodeCopyButton(at point: NSPoint) {
        // Keep the button up while the pointer is ON it. It is parked just above the block, so
        // reaching for it leaves the block's hit area — without this the button vanishes the moment
        // you move toward it and can never be clicked.
        if !codeCopyButton.isHidden,
           codeCopyButton.frame.insetBy(dx: -4, dy: -4).contains(convert(point, to: bubble)) {
            return
        }
        let inText = convert(point, to: textView)
        guard let code = codeBlock(at: inText) else { return hideCodeCopyButton() }
        let source = code.source
        let rect = code.rect

        hoveredCode = (source, rect)
        let size = NSSize(width: 22, height: 18)
        // Which of the block's edges is visually "top" depends on the flippedness of both views, and
        // assuming it put the button under the block, then in the middle of the code. Convert BOTH
        // edges and take the visually higher one — in an unflipped superview that is the larger y.
        let edgeA = textView.convert(NSPoint(x: rect.maxX, y: rect.minY), to: bubble)
        let edgeB = textView.convert(NSPoint(x: rect.maxX, y: rect.maxY), to: bubble)
        let top = max(edgeA.y, edgeB.y)
        // Sit INSIDE the block's top-right corner. Placing it above the block put it outside the
        // bubble entirely whenever the block was the message's first element — visible on a block
        // with text above it, invisible on one without.
        codeCopyButton.frame = NSRect(
            x: max(edgeA.x, edgeB.x) - size.width - 8,
            y: top - size.height - 4,
            width: size.width, height: size.height)
        codeCopyButton.isHidden = false
    }

    // MARK: - Find

    /// The match this cell keeps highlighted, if any.
    private var findHighlight: (query: String, occurrence: Int)?
    /// What was under the highlight before it was applied, so clearing restores rather than strips.
    /// The markdown renderer gives inline code its own background; blanket-removing
    /// `.backgroundColor` would take those with it.
    private var savedHighlightAttributes: [(NSRange, NSColor?, NSColor?)] = []

    /// Highlight the `occurrence`-th hit of `query` in this cell and **keep it highlighted**.
    ///
    /// Persistent rather than `showFindIndicator` alone. That call is AppKit's transient flash: it
    /// fades after about a second by design, which is right as a flourish on top of a selection and
    /// wrong as the only indication of where a match is. Safari and TextEdit flash *and* leave the
    /// match selected; this leaves it highlighted.
    ///
    /// **Searched against the rendered text, not the entry's source.** This cell holds markdown that
    /// has been rendered — `**`, backticks and heading marks are consumed — so a UTF-16 offset into
    /// the source points somewhere else on screen. Counting occurrences in the rendered string
    /// survives that, and is the more faithful thing to highlight: the rendered text is what the
    /// user was reading when they searched.
    @discardableResult
    func setFindHighlight(query: String, occurrence: Int) -> Bool {
        clearFindHighlight()
        guard !query.isEmpty else { return false }
        findHighlight = (query, occurrence)
        return applyFindHighlight(revealing: true)
    }

    func clearFindHighlight() {
        guard findHighlight != nil || !savedHighlightAttributes.isEmpty else { return }
        findHighlight = nil
        removeFindHighlightPaint()
    }

    /// Restore renderer-owned attributes without forgetting which match the coordinator wants.
    /// Incremental storage edits call this before ranges move, then `applyFindHighlight` paints the
    /// same logical occurrence again against the updated rendered text.
    private func removeFindHighlightPaint() {
        guard let storage = textView.textStorage else { savedHighlightAttributes = []; return }
        for (range, background, foreground) in savedHighlightAttributes {
            guard NSMaxRange(range) <= storage.length else { continue }
            if let background { storage.addAttribute(.backgroundColor, value: background, range: range) }
            else { storage.removeAttribute(.backgroundColor, range: range) }
            if let foreground { storage.addAttribute(.foregroundColor, value: foreground, range: range) }
            else { storage.removeAttribute(.foregroundColor, range: range) }
        }
        savedHighlightAttributes = []
    }

    /// Re-applied after every render, because a render replaces the whole text storage.
    @discardableResult
    private func applyFindHighlight(revealing: Bool = false) -> Bool {
        savedHighlightAttributes = []
        guard let (query, occurrence) = findHighlight,
              let storage = textView.textStorage, storage.length > 0,
              let layoutManager = textView.layoutManager,
              let container = textView.textContainer
        else { return false }

        let text = storage.string as NSString
        var location = 0
        var remaining = occurrence
        var found = NSRange(location: NSNotFound, length: 0)
        while location < text.length {
            let hit = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive],
                                 range: NSRange(location: location, length: text.length - location))
            guard hit.location != NSNotFound else { break }
            if remaining == 0 { found = hit; break }
            remaining -= 1
            location = hit.location + max(hit.length, 1)
        }
        // Fewer rendered hits than source hits is expected when markdown was consumed between them;
        // highlighting the first beats highlighting nothing when the row is otherwise correct.
        if found.location == NSNotFound {
            let first = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive])
            guard first.location != NSNotFound else { return false }
            found = first
        }

        // Save what is being covered, then paint. Both colours: a yellow background under the
        // cell's own light-on-dark body text would be unreadable, so the ink is pinned too.
        storage.enumerateAttributes(in: found, options: []) { attributes, range, _ in
            self.savedHighlightAttributes.append(
                (range, attributes[.backgroundColor] as? NSColor, attributes[.foregroundColor] as? NSColor))
        }
        storage.addAttribute(.backgroundColor, value: NSColor.systemYellow, range: found)
        storage.addAttribute(.foregroundColor, value: NSColor.black, range: found)

        guard revealing else { return true }
        layoutManager.ensureLayout(forCharacterRange: found)
        guard layoutManager.boundingRect(forGlyphRange:
                layoutManager.glyphRange(forCharacterRange: found, actualCharacterRange: nil),
                in: container).height > 0 else { return true }
        // `scrollRowToVisible` only promises the ROW is visible, and an assistant row can be taller
        // than the viewport — a match near its top lands off-screen with the row's bottom showing,
        // which reads exactly like Find not working. Scroll the range itself, which walks up through
        // the cell and the table to the transcript's clip view. Programmatic, so the pin controller
        // does not see it as user input.
        textView.scrollRangeToVisible(found)
        // The flash still fires, on top of the persistent highlight, because it is genuinely good at
        // drawing the eye to where the match landed.
        textView.showFindIndicator(for: found)
        return true
    }

    /// Resolve the current TextKit block rather than trusting the shared hover button's cached
    /// payload. Layout can move a different block under a stationary pointer before mouseMoved is
    /// delivered, and copying stale text is worse than hiding an invalid affordance.
    private func codeBlock(at inText: NSPoint) -> (source: String, rect: NSRect)? {
        guard let layoutManager = textView.layoutManager,
              let container = textView.textContainer,
              let storage = textView.textStorage, storage.length > 0
        else { return nil }

        var fraction: CGFloat = 0
        let index = layoutManager.characterIndex(
            for: inText, in: container, fractionOfDistanceBetweenInsertionPoints: &fraction)
        guard index < storage.length else { return nil }

        var range = NSRange(location: 0, length: 0)
        // longestEffectiveRange, not effectiveRange: syntax highlighting splits the block into many
        // runs, and the shorter form stops at the first boundary — which measured one line tall
        // instead of the whole block, putting the button in the middle of the code.
        guard let source = storage.attribute(
            .mechanicianCodeSource, at: index,
            longestEffectiveRange: &range,
            in: NSRange(location: 0, length: storage.length)) as? String
        else { return nil }

        // characterIndex(for:) snaps to the NEAREST glyph, so a point in the margin beside a block
        // still resolves into it. Require the pointer to be genuinely inside the block's rect.
        let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: container)
        rect.origin.x += textView.textContainerInset.width
        rect.origin.y += textView.textContainerInset.height
        guard rect.insetBy(dx: -6, dy: -2).contains(inText) else { return nil }
        return (source, rect)
    }

    private func hideCodeCopyButton() {
        hoveredCode = nil
        if !codeCopyButton.isHidden { codeCopyButton.isHidden = true }
    }

    @objc private func copyHoveredCode() {
        copyCodeUnderButton(to: .general)
    }

    /// Internal for a clipboard-isolated AppKit regression test; the UI action always supplies the
    /// general pasteboard.
    func copyCodeUnderButton(to pasteboard: NSPasteboard) {
        // Re-hit-test at the visible button's center. TextKit may have reflowed since the last
        // mouseMoved event, so the cached source is only suitable for drawing, never for copying.
        let buttonCenter = NSPoint(x: codeCopyButton.frame.midX, y: codeCopyButton.frame.midY)
        let inText = bubble.convert(buttonCenter, to: textView)
        guard let current = codeBlock(at: inText) else {
            hideCodeCopyButton()
            return
        }
        hoveredCode = current
        pasteboard.clearContents()
        pasteboard.setString(current.source, forType: .string)
        // The same green-checkmark confirmation the row actions use, so copying a block and copying
        // a message feel like one gesture rather than two different controls.
        confirmClick(on: codeCopyButton)
    }
}

final class HoverActionButton: NSButton {
    var onHoverChange: ((Bool) -> Void)?
    private(set) var isHovering = false
    private var hoverTracking: NSTrackingArea?

    override var isHidden: Bool {
        didSet {
            if isHidden { setHovering(false) }
            else { reconcileHoverState() }
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow],
            owner: self,
            userInfo: nil)
        addTrackingArea(area)
        hoverTracking = area
        reconcileHoverState()
    }

    override func mouseEntered(with event: NSEvent) {
        // Receiving this event already proves the key-window tracking policy is active. Check the
        // exact hit rectangle, but do not re-query key-window state (it can change between dispatch
        // and handling during window activation).
        setHovering(!isHidden && bounds.contains(convert(event.locationInWindow, from: nil)))
    }

    override func mouseExited(with event: NSEvent) {
        setHovering(false)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        reconcileHoverState()
    }

    /// Reused transcript rows can move beneath a stationary pointer without producing a balanced
    /// enter/exit pair. Derive hover from the current pointer and exact button bounds instead of
    /// treating tracking events as durable state.
    func reconcileHoverState() {
        guard !isHidden, let window, window.isKeyWindow else {
            setHovering(false)
            return
        }
        let location = window.mouseLocationOutsideOfEventStream
        setHovering(bounds.contains(convert(location, from: nil)))
    }

    private func setHovering(_ hovering: Bool) {
        guard hovering != isHovering else { return }
        isHovering = hovering
        onHoverChange?(hovering)
    }
}

@MainActor
private final class NativeAssistantBubbleView: NSView {
    var topPadding: CGFloat = 0
    var isReview = false {
        didSet { updateAppearance() }
    }
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        updateAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
    }

    private func updateAppearance() {
        let appearance = effectiveAppearance
        layer?.backgroundColor = NSColor.nSurface.mechanicianCGColor(in: appearance)
        layer?.borderWidth = isReview ? 1 : 0
        layer?.borderColor = isReview
            ? NSColor.controlAccentColor
                .mechanicianCGColor(in: appearance, alpha: 0.34)
            : NSColor.clear.mechanicianCGColor(in: appearance)
    }
}

@MainActor
enum NativeMarkdownRenderer {
    static func render(
        _ markdown: String,
        scale: CGFloat,
        followedByMoreBlocks: Bool = false
    ) -> NSAttributedString {
        let output = NSMutableAttributedString()
        let blocks = MarkdownText.blocks(from: markdown)
        if blocks.isEmpty {
            return NSAttributedString(string: " ", attributes: baseAttributes(scale: scale))
        }

        for (index, block) in blocks.enumerated() {
            let blockStart = output.length
            switch block.kind {
            case .heading(let level):
                let size: CGFloat = level == 1 ? 20 : (level == 2 ? 16 : 14)
                let font = NSFont.systemFont(ofSize: size * scale, weight: .semibold)
                output.append(inline(block.content, font: font))
            case .bullet:
                output.append(inline("•  \(block.content)", font: baseFont(scale: scale)))
            case .numbered(let marker):
                output.append(inline("\(marker)  \(block.content)", font: baseFont(scale: scale)))
            case .paragraph:
                output.append(inline(block.content, font: baseFont(scale: scale)))
            case .code:
                output.append(
                    codeBlock(block.content, language: block.language, scale: scale))
            case .rule:
                output.append(NSAttributedString(
                    string: "────────────────────────",
                    attributes: [
                        .font: NSFont.systemFont(ofSize: 9 * scale),
                        .foregroundColor: NSColor.separatorColor,
                    ]))
            case .table:
                let rows = block.tableRows ?? []
                output.append(table(rows, scale: scale))
            }

            let blockRange = NSRange(location: blockStart, length: output.length - blockStart)
            // Code, like tables, carries its own paragraph style holding the text block that
            // draws its background. Overwriting it here would drop the block and fall back to
            // per-line glyph highlighting.
            if blockRange.length > 0, block.kind != .table, block.kind != .code {
                let paragraph = NSMutableParagraphStyle()
                paragraph.lineSpacing = 1.5 * scale
                paragraph.paragraphSpacing = index == blocks.count - 1 && !followedByMoreBlocks
                    ? 0 : 6 * scale
                output.addAttribute(.paragraphStyle, value: paragraph, range: blockRange)
            }
            if index != blocks.count - 1 || followedByMoreBlocks {
                output.append(NSAttributedString(string: "\n"))
            }
        }
        return output
    }

    /// Render fenced code as one full-width text block. A `.backgroundColor` text attribute
    /// paints only behind the glyphs of each line fragment, so every line got its own
    /// ragged-right rectangle with no padding and no shared container. `NSTextTableBlock` is
    /// the same mechanism the table renderer below already relies on, and draws a single
    /// continuous, padded background across every line of the block.
    private static func codeBlock(
        _ content: String,
        language: String?,
        scale: CGFloat
    ) -> NSAttributedString {
        let table = NSTextTable()
        table.numberOfColumns = 1
        table.layoutAlgorithm = .automaticLayoutAlgorithm
        table.collapsesBorders = true
        table.hidesEmptyCells = false
        table.setValue(100, type: .percentageValueType, for: .width)

        let block = NSTextTableBlock(
            table: table, startingRow: 0, rowSpan: 1, startingColumn: 0, columnSpan: 1)
        block.setWidth(10 * scale, type: .absoluteValueType, for: .padding)
        block.backgroundColor = NSColor.nBg

        let paragraph = NSMutableParagraphStyle()
        paragraph.textBlocks = [block]
        paragraph.lineSpacing = 1.5 * scale

        // The highlighter returns a SwiftUI AttributedString, whose `.font` and `.foregroundColor`
        // live in the SwiftUI attribute scope. Bridging it straight to NSAttributedString keeps
        // those keys but AppKit reads neither, so code rendered in the proportional body font with
        // no highlighting at all. Translate each run into AppKit attributes instead.
        let highlighted = SyntaxHighlighter.highlight(
            content, language: language, fontSize: 12 * scale)
        let mono = NSFont.monospacedSystemFont(ofSize: 12 * scale, weight: .regular)
        let body = NSMutableAttributedString()
        for run in highlighted.runs {
            var attributes: [NSAttributedString.Key: Any] = [.font: mono]
            if let color = run.foregroundColor {
                attributes[.foregroundColor] = NSColor(color)
            }
            body.append(NSAttributedString(
                string: String(highlighted[run.range].characters), attributes: attributes))
        }
        // The cell's content must end on a paragraph break or TextKit leaves the block open
        // and the following markdown block is absorbed into its background.
        if body.string.hasSuffix("\n") == false {
            body.append(NSAttributedString(string: "\n"))
        }
        body.addAttribute(
            .paragraphStyle, value: paragraph,
            range: NSRange(location: 0, length: body.length))
        // Carry the ORIGINAL source on the range. The rendered run is syntax-highlighted and may be
        // re-wrapped, so recovering the text to copy from the glyphs would not round-trip; the cell
        // reads this attribute to find each block and copy exactly what the model wrote.
        body.addAttribute(
            .mechanicianCodeSource, value: content,
            range: NSRange(location: 0, length: body.length))
        return body
    }

    /// Render GFM tables as native TextKit table blocks. The native transcript host originally
    /// flattened parsed rows back into pipe-delimited monospace text, even though the SwiftUI
    /// fallback rendered the same block as a grid. NSTextTable keeps the content selectable and
    /// measurable by the cell's existing TextKit layout without introducing a nested scroll view.
    private static func table(_ rows: [[String]], scale: CGFloat) -> NSAttributedString {
        guard !rows.isEmpty else { return NSAttributedString() }
        let columnCount = rows.map(\.count).max() ?? 0
        guard columnCount > 0 else { return NSAttributedString() }

        let table = NSTextTable()
        table.numberOfColumns = columnCount
        table.layoutAlgorithm = .automaticLayoutAlgorithm
        table.collapsesBorders = true
        table.hidesEmptyCells = false
        table.setValue(100, type: .percentageValueType, for: .width)

        let output = NSMutableAttributedString()
        for (rowIndex, row) in rows.enumerated() {
            for columnIndex in 0..<columnCount {
                let block = NSTextTableBlock(
                    table: table,
                    startingRow: rowIndex,
                    rowSpan: 1,
                    startingColumn: columnIndex,
                    columnSpan: 1)
                block.setWidth(1, type: .absoluteValueType, for: .border)
                block.setBorderColor(NSColor.separatorColor)
                block.setWidth(6 * scale, type: .absoluteValueType, for: .padding)
                if rowIndex == 0 { block.backgroundColor = NSColor.nElevated }

                let paragraph = NSMutableParagraphStyle()
                paragraph.textBlocks = [block]
                paragraph.lineSpacing = 1.5 * scale

                let font = NSFont.systemFont(
                    ofSize: 12 * scale,
                    weight: rowIndex == 0 ? .semibold : .regular)
                let cell = NSMutableAttributedString(
                    attributedString: inline(
                        columnIndex < row.count ? row[columnIndex] : "",
                        font: font))
                cell.addAttribute(
                    .paragraphStyle,
                    value: paragraph,
                    range: NSRange(location: 0, length: cell.length))
                output.append(cell)
                output.append(NSAttributedString(
                    string: "\n",
                    attributes: [.paragraphStyle: paragraph, .font: font]))
            }
        }
        return output
    }

    private static func inline(_ source: String, font: NSFont) -> NSAttributedString {
        let parsed = NSMutableAttributedString(
            attributedString: NSAttributedString(MarkdownText.inline(source)))
        let whole = NSRange(location: 0, length: parsed.length)
        parsed.addAttributes([.font: font, .foregroundColor: NSColor.labelColor], range: whole)
        parsed.enumerateAttribute(
            .inlinePresentationIntent, in: whole, options: []) { value, range, _ in
                let raw = (value as? NSNumber)?.intValue ?? 0
                let intent = InlinePresentationIntent(rawValue: UInt(raw))
                var runFont = font
                if intent.contains(.code) {
                    runFont = NSFont.monospacedSystemFont(ofSize: font.pointSize, weight: .regular)
                    parsed.addAttribute(.backgroundColor, value: NSColor.nElevated, range: range)
                } else {
                    var traits: NSFontTraitMask = []
                    if intent.contains(.stronglyEmphasized) { traits.insert(.boldFontMask) }
                    if intent.contains(.emphasized) { traits.insert(.italicFontMask) }
                    if !traits.isEmpty {
                        runFont = NSFontManager.shared.convert(font, toHaveTrait: traits)
                    }
                }
                parsed.addAttribute(.font, value: runFont, range: range)
                if intent.contains(.strikethrough) {
                    parsed.addAttribute(
                        .strikethroughStyle,
                        value: NSUnderlineStyle.single.rawValue,
                        range: range)
                }
            }
        return parsed
    }

    private static func baseFont(scale: CGFloat) -> NSFont {
        NSFont.systemFont(ofSize: 13 * scale)
    }

    private static func baseAttributes(scale: CGFloat) -> [NSAttributedString.Key: Any] {
        [.font: baseFont(scale: scale), .foregroundColor: NSColor.labelColor]
    }
}

extension NSAttributedString.Key {
    /// The verbatim source of a fenced code block, attached to its rendered range so the transcript
    /// can offer a copy affordance that yields exactly what the model wrote (FR-121).
    static let mechanicianCodeSource = NSAttributedString.Key("mechanicianCodeSource")
}
