import SwiftUI
import AppKit

/// Multi-line chat input: Enter sends, Shift+Enter inserts a newline, and the box
/// auto-grows with content (up to a cap, then scrolls). A local Cmd+V monitor turns a
/// pasted image into an inline thumbnail preview and a pasted large text blob into a
/// compact inline pill. Artifact drags and generic files use the same marker mechanism, carrying
/// durable compact references instead of degrading to temporary/external file paths. Every marker
/// stays at the authored position while its provider-facing payload is carried in a hidden
/// attribute and expanded only when the message is sent. Small text pastes normally.
/// NSTextView subclass whose only job is to route paste through the composer's attachment logic —
/// the reliable interception point. (A local ⌘V event monitor's `return nil` does NOT suppress the
/// default menu/responder paste, so the pasted text was inserted twice.) It adds NO stored
/// properties, so it's installed via `object_setClass` on the view `scrollableTextView()` builds.
/// Styling for the composer's insertion point.
///
/// The caret is the one place the eye actually rests while typing, so this stays deliberately
/// quiet: its hue is sampled from the same six-ray `MagicLaserSpectrum` the activity outline drifts
/// through. The drift is far slower than typing, so it never competes with reading — it just stops
/// the caret reading as borrowed system chrome.
///
/// Only colour is ours to set. Since macOS 15 the caret is an `NSTextInsertionIndicator` subview
/// that sizes and draws itself — its frame is reported zero-width — so its shape and blink belong
/// to AppKit, and the legacy `drawInsertionPoint(in:color:turnedOn:)` hook is never called at all.
/// That is a good trade: the system indicator is already a rounded modern caret, and it keeps
/// input-method composition working correctly.
enum ComposerCaret {
    /// Alpha applied while a turn is in flight, when typing queues rather than sends.
    static let inFlightAlpha: CGFloat = 0.42
    /// How often the tint is resampled. The drift period is measured in tens of seconds, so this
    /// is far finer than the eye can resolve while still being a trivial amount of work.
    static let refreshInterval: TimeInterval = 0.4

    /// A phosphor bloom, carried as a zero-offset shadow on the indicator's own layer so it tracks
    /// the caret exactly rather than being chased into position a frame later.
    static let glowRadius: CGFloat = 3
    static let baseGlowOpacity: Float = 0.7

    /// Reduce Transparency and Increase Contrast are both requests for a harder edge, and a bloom
    /// is the opposite of that. Drop it rather than soften it.
    static func glowOpacity(increaseContrast: Bool, reduceTransparency: Bool) -> Float {
        (increaseContrast || reduceTransparency) ? 0 : baseGlowOpacity
    }

    /// Where in the palette the caret currently sits. Shares the outline's drift period, so the
    /// two agree over time without being brittlely phase-locked to one another.
    static func driftPhase(at time: CFTimeInterval, reduceMotion: Bool) -> Double {
        guard !reduceMotion else { return 0 }
        let period = ComposerBreathingRhythm.paletteDriftPeriod
        return (time.truncatingRemainder(dividingBy: period)) / period
    }

    static func color(
        driftPhase: Double,
        isDark: Bool,
        inFlight: Bool,
        increaseContrast: Bool
    ) -> NSColor {
        let alpha: CGFloat = inFlight ? inFlightAlpha : 1
        // Increase Contrast is an explicit request for legibility over personality.
        guard !increaseContrast else {
            return NSColor.labelColor.withAlphaComponent(alpha)
        }
        let sampled = MagicLaserSpectrum.rgb(at: driftPhase, isDark: isDark)
        return NSColor(
            srgbRed: CGFloat(sampled.r),
            green: CGFloat(sampled.g),
            blue: CGFloat(sampled.b),
            alpha: alpha)
    }
}

/// The composer's own text-editing undo stack, and the rule that decides who owns ⌘Z.
extension NSTextView {
    /// Where a composer edit must register: the composer's own stack, never the workspace's.
    ///
    /// Spelled out rather than using `undoManager` so the intent survives a future change to that
    /// property. Only text editing belongs on this stack.
    var composerUndoManager: UndoManager? {
        (self as? ComposerTextView)?.ownUndoManager ?? undoManager
    }
}

final class ComposerTextView: NSTextView {
    /// The composer's own text-editing stack.
    ///
    /// `NSTextView` does **not** own an undo manager. Measured against AppKit directly: a text view
    /// with `allowsUndo` returns whatever the window delegate vends from
    /// `windowWillReturnUndoManager`, and typing registers on that same object. Left alone, typing
    /// would land on the workspace's library stack, so ⌘Z would interleave "undo my last word" with
    /// "put that conversation back". The composer therefore keeps its own.
    let ownUndoManager = UndoManager()

    /// Always the composer's own, unconditionally.
    ///
    /// `NSTextView` registers typing *through* this property, so anything else returned here would
    /// put keystrokes on that stack instead. It is also what `NSWindow.undoManager` resolves to
    /// while this view has focus, which is precisely why the ⌘Z decision cannot live here — see
    /// `WorkspaceWindow`.
    override var undoManager: UndoManager? { ownUndoManager }

    // ⌘Z routing deliberately does NOT live here. `NSWindow.undoManager` consults the first
    // responder before the delegate, so anything this view vends becomes what AppKit's own `undo:`
    // acts on — which made the library stack unreachable. `WorkspaceWindow` owns the decision and
    // reads this view's `ownUndoManager` directly.

    /// Continuity Camera: Take Photo, Scan Documents, and Add Sketch from a nearby iPhone or iPad.
    ///
    /// macOS offers these by inserting an "Import from iPhone or iPad" menu into the context menu of
    /// any responder that declares itself able to receive images. `NSTextView` does not declare that
    /// on its own — measured, with `isRichText` and `importsGraphics` both on, it returns nil for
    /// `public.png`, `public.tiff`, and `public.file-url`, and its context menu carries no import
    /// item. Declaring it here is what turns the feature on.
    ///
    /// It also earns us the one capture the Mac has no API for: there is no public document scanner
    /// on macOS, so multi-page scanning with edge detection can only arrive this way.
    override func validRequestor(
        forSendType sendType: NSPasteboard.PasteboardType?,
        returnType: NSPasteboard.PasteboardType?
    ) -> Any? {
        if sendType == nil, let returnType,
           Self.continuityCameraReturnTypes.contains(returnType) {
            return self
        }
        return super.validRequestor(forSendType: sendType, returnType: returnType)
    }

    static let continuityCameraReturnTypes: Set<NSPasteboard.PasteboardType> = [
        .png, .tiff, .fileURL, .pdf,
    ]

    /// The imported photo, scan, or sketch arrives on a pasteboard, which is exactly the shape the
    /// composer's paste path already handles: image bytes become a temp file plus an inline
    /// thumbnail, a file URL becomes an attachment chip. Routing through it rather than letting
    /// `NSTextView` insert a bare attachment is what keeps the payload token intact, so the agent
    /// receives a real path instead of an image the serializer cannot name.
    override func readSelection(from pboard: NSPasteboard) -> Bool {
        guard let coordinator = delegate as? ChatInput.Coordinator else {
            return super.readSelection(from: pboard)
        }
        return coordinator.handlePaste(from: pboard, into: self)
    }

    /// `NSTextView` periodically rebuilds its drag registration from this property (for example
    /// when rich-text/import settings change). A one-time `registerForDraggedTypes` call is therefore
    /// not durable: the editor can silently stop advertising the private artifact type before the
    /// user begins a drag. Extend the text system's source of truth instead.
    override var acceptableDragTypes: [NSPasteboard.PasteboardType] {
        var types = super.acceptableDragTypes
        let attachmentTypes = [
            ComposerAttachmentDragDescriptor.pasteboardType,
            ArtifactActions.referencePasteboardType,
            NSPasteboard.PasteboardType.fileURL,
        ] + ConversationFilePromiseMaterializer.readablePasteboardTypes
            + MailMessageDragReceiver.readablePasteboardTypes
        for type in attachmentTypes
        where !types.contains(type) {
            types.append(type)
        }
        return types
    }

    override func updateDragTypeRegistration() {
        super.updateDragTypeRegistration()
        // NSTextView's refresh updates its semantic policy but does not reliably propagate custom
        // types into NSView.registeredDraggedTypes. Register the resulting source-of-truth list on
        // the concrete destination every time the text system refreshes it.
        registerForDraggedTypes(acceptableDragTypes)
    }

    /// Publish native edits from the text view itself. The scrollable NSTextView used by the
    /// product can visibly accept keyboard input without reliably reaching the delegate's
    /// `textDidChange` callback during SwiftUI host updates. That left the AppKit editor showing
    /// text while the observable draft—and therefore Send/Guide enablement—remained empty.
    /// `didChangeText()` is the AppKit edit boundary for typing, deletion, undo, and input methods,
    /// so route that boundary directly to the coordinator instead of relying on a second
    /// notification hop.
    override func didChangeText() {
        super.didChangeText()
        (delegate as? ChatInput.Coordinator)?.nativeTextDidChange(self)
    }

    /// Attachment payloads in authored order.
    ///
    /// Read per attachment character rather than per attribute run: two identical adjacent
    /// attachments coalesce into a single run, which would otherwise announce one of them.
    func attachmentPayloadsInAuthoredOrder() -> [String] {
        guard let storage = textStorage, storage.length > 0 else { return [] }
        var payloads: [String] = []
        storage.enumerateAttribute(
            .attachment,
            in: NSRange(location: 0, length: storage.length)
        ) { value, range, _ in
            guard value != nil else { return }
            for index in range.location..<NSMaxRange(range) {
                guard let payload = storage.attribute(
                    ChatInput.payloadKey,
                    at: index,
                    effectiveRange: nil) as? String else { continue }
                payloads.append(payload)
            }
        }
        return payloads
    }

    /// Announce attachments on the field itself. They cannot be folded into the accessibility
    /// *value*, because that is a read/write channel — `setAccessibilityValue` replaces the draft,
    /// so a client that read a flattened value and wrote it back would replace real attachments
    /// with their spoken descriptions.
    override func accessibilityLabel() -> String? {
        ChatInput.composerAccessibilityLabel(
            attachmentPayloads: attachmentPayloadsInAuthoredOrder())
            ?? super.accessibilityLabel()
    }

    override func copy(_ sender: Any?) {
        let payload = (delegate as? ChatInput.Coordinator)?
            .composerClipboardPayload(from: self)
        super.copy(sender)
        if let payload {
            (delegate as? ChatInput.Coordinator)?
                .addComposerClipboardPayload(payload, to: .general)
        }
    }

    override func cut(_ sender: Any?) {
        // Capture the attributed selection before AppKit removes it, then add the private ordered
        // representation beside the native public clipboard types produced by NSTextView.
        guard let coordinator = delegate as? ChatInput.Coordinator,
              let payload = coordinator.composerClipboardPayload(from: self),
              payload.requiresPrivateRepresentation else {
            super.cut(sender)
            return
        }
        // A private representation is the only lossless form for attachment tokens. If a selected
        // payload exceeds the bounded clipboard envelope, do not delete the source and leave the
        // user with only AppKit's attachment character/readable placeholder on the clipboard.
        // Oversized plain text remains safe because NSTextView publishes its exact string itself.
        guard let data = payload.processSignedEncodedData else {
            NSSound.beep()
            return
        }
        // Copy first and verify the lossless private flavor before deleting. Re-encoding after
        // `super.cut` left a rare allocation/pasteboard-failure window in which the only source had
        // already disappeared. `deleteBackward` preserves AppKit's normal edit/undo behavior.
        super.copy(sender)
        guard coordinator.addComposerClipboardPayload(
            payload,
            processSignedData: data,
            to: .general
        ) else {
            NSSound.beep()
            return
        }
        deleteBackward(sender)
    }

    override func paste(_ sender: Any?) {
        if (delegate as? ChatInput.Coordinator)?.handlePaste(into: self) == true { return }
        if (delegate as? ChatInput.Coordinator)?.handleForgedTokenPaste(into: self) == true { return }
        super.paste(sender)
    }
    override func pasteAsPlainText(_ sender: Any?) {
        if (delegate as? ChatInput.Coordinator)?.handlePaste(into: self) == true { return }
        if (delegate as? ChatInput.Coordinator)?.handleForgedTokenPaste(into: self) == true { return }
        super.pasteAsPlainText(sender)
    }

    /// Attachment tokens are otherwise just one attributed replacement character to AppKit. Claim
    /// a primary-button press only when it lands inside that glyph's rendered bounds, then start a
    /// private dragging session once the pointer moves. Ordinary text selection remains native.
    /// Kept, but do not rely on it: measured on macOS 27, this is never entered. `NSTextView`
    /// installs its own gesture recognizers and one consumes the press before the view's mouse
    /// methods see it, which is why arming a drag here silently did nothing for so long. The drag
    /// arms in `mouseDragged` instead.
    override func mouseDown(with event: NSEvent) {
        guard event.clickCount == 1,
              (delegate as? ChatInput.Coordinator)?
                .prepareAttachmentDrag(
                    at: convert(event.locationInWindow, from: nil), in: self)
                == true else {
            super.mouseDown(with: event)
            return
        }
        window?.makeFirstResponder(self)
    }

    /// Start the drag from the drag itself, not from a remembered press.
    ///
    /// Measured, after two wrong guesses: the window's hit test returns this editor and the press is
    /// over it, but `mouseDown` is never entered — `NSTextView` installs its own gesture recognizers,
    /// and one of them consumes the press before the view's mouse methods see it. `mouseDragged` is
    /// still delivered. Anything that arms on `mouseDown` therefore cannot work, which is why
    /// reordering never started however much the drop side was fixed.
    override func mouseDragged(with event: NSEvent) {
        guard let coordinator = delegate as? ChatInput.Coordinator else {
            super.mouseDragged(with: event)
            return
        }
        if coordinator.beginPreparedAttachmentDrag(from: self, event: event) { return }
        // Not armed, because the press never arrived. Arm from where the pointer is now: at the start
        // of a drag it is still inside the glyph the person grabbed.
        if !coordinator.hasActiveAttachmentDrag,
           coordinator.prepareAttachmentDrag(
            at: convert(event.locationInWindow, from: nil), in: self),
           coordinator.beginPreparedAttachmentDrag(from: self, event: event) {
            return
        }
        super.mouseDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        if (delegate as? ChatInput.Coordinator)?.cancelPreparedAttachmentDrag() == true {
            return
        }
        super.mouseUp(with: event)
    }

    /// A composer token is a move only when its own private descriptor returns to this composer.
    /// Everywhere else—including another app—the source remains intact and the advertised text/file
    /// representation is copied.
    override func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        guard (delegate as? ChatInput.Coordinator)?.hasActiveAttachmentDrag == true else {
            return super.draggingSession(session, sourceOperationMaskFor: context)
        }
        return context == .outsideApplication ? .copy : [.copy, .move]
    }

    override func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        (delegate as? ChatInput.Coordinator)?.finishAttachmentDrag()
        super.draggingSession(session, endedAt: screenPoint, operation: operation)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        (delegate as? ChatInput.Coordinator)?.refreshFileAttachmentAppearance(in: self)
    }

    /// Whether a drop needs the window fronted first.
    ///
    /// `draggingSource` is nil exactly when the drag came from another application, which is the only
    /// case that needs it. An intra-application drag already has our app active, and activating again
    /// mid-session is what broke same-composer reordering.
    static func shouldFrontWindowForDrop(draggingSource: Any?) -> Bool {
        draggingSource == nil
    }

    /// NSTextView consumes drags before a SwiftUI ancestor can see them. Registering the concrete
    /// native editor as the destination is what makes Finder/artifact → command composer reliable.
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let coordinator = delegate as? ChatInput.Coordinator,
              coordinator.canHandleDrop(from: sender.draggingPasteboard) else {
            return super.draggingEntered(sender)
        }
        // Finder may own the active Space/window when the drag starts, so front the destination while
        // preserving the live session. ONLY for a drag that came from another application: doing it
        // for a drag that started in this very composer re-activates the app and re-keys the window
        // underneath its own in-flight session, which is why reordering an attachment never landed.
        if ComposerTextView.shouldFrontWindowForDrop(draggingSource: sender.draggingSource) {
            NSApp.activate(ignoringOtherApps: true)
            window?.makeKeyAndOrderFront(nil)
        }
        return coordinator.dropOperation(for: sender.draggingPasteboard)
    }

    /// Keep ownership of the session while the pointer moves over the native editor. Falling back
    /// to NSTextView here lets its built-in rich-text policy replace the `.copy` returned on entry,
    /// which is why a valid artifact could show briefly and then become an invalid drop.
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let coordinator = delegate as? ChatInput.Coordinator,
              coordinator.canHandleDrop(from: sender.draggingPasteboard) else {
            return super.draggingUpdated(sender)
        }
        return coordinator.dropOperation(for: sender.draggingPasteboard)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard (delegate as? ChatInput.Coordinator)?
            .canHandleDrop(from: sender.draggingPasteboard) == true else {
            return super.prepareForDragOperation(sender)
        }
        return true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let insertionIndex = characterIndexForInsertion(
            at: convert(sender.draggingLocation, from: nil))
        if (delegate as? ChatInput.Coordinator)?
            .handleDrop(
                from: sender.draggingPasteboard,
                into: self,
                insertionIndex: insertionIndex) == true {
            return true
        }
        return super.performDragOperation(sender)
    }
}

struct ChatInput: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    var isEnabled: Bool
    var fontSize: CGFloat = 13
    /// Bumped by the owner to request keyboard focus (e.g. on New Conversation).
    /// Installed on the editor so AppKit owns first-responder state directly.
    var focusController: ComposerFocusController? = nil
    var onSend: () -> Void
    var onInterject: (() -> Void)? = nil
    /// Skills surfaced by the SDK (`bridge.slashCommands`) for inline "/…" autocomplete.
    var slashCommands: [SlashCommandInfo] = []
    /// Working directory for @-path autocomplete (relative paths resolve against it).
    var cwd: String = ""
    /// Owns pasted screenshot media. A nil id is used only by isolated/unit-test composers.
    var conversationID: UUID? = nil
    /// Injection seam for focused attachment tests. Product composers use the shared store.
    var attachmentStore: ConversationStore? = nil
    /// Artifact identity is process-global in production. Injection keeps security-boundary tests
    /// isolated while exercising the exact same durable-UUID lookup as the live composer.
    var artifactStore: ArtifactStore = .shared
    /// Native artifact exports are process scratch. Tests override the root so a forged-token
    /// regression never shares temporary files or live identity mappings with a running app.
    var artifactExportRoot: URL = ArtifactFileExport.temporaryExportsRoot
    /// Dims the caret while a turn is running, so the box says "this will queue" before you type
    /// rather than after you press Return.
    var isTurnInFlight: Bool = false
    /// Lets the owning conversation link the referenced durable artifact into its live preview so
    /// a same-title CreateOrUpdateArtifact call revises that artifact rather than a detached export.
    var onArtifactReference: ((ArtifactDragReference) -> Void)? = nil
    /// Resolves the original conversation's stored draft if a promise finishes after navigation.
    /// Same-conversation replacement stays inside the native editor to preserve caret and undo.
    var canResolvePromisedAttachment: ((
        _ conversationID: UUID,
        _ pendingPayload: String
    ) -> Bool)? = nil
    var onPromisedAttachmentResolution: ((
        _ conversationID: UUID,
        _ pendingPayload: String,
        _ replacementPayload: String
    ) -> Bool)? = nil
    /// File-promise staging can outlive the visible composer. The owner uses these balanced hooks to
    /// keep the original Conversation resident until its durable pending marker is resolved.
    var onPromisedAttachmentTransferBegan: ((_ conversationID: UUID) -> Void)? = nil
    var onPromisedAttachmentTransferEnded: ((_ conversationID: UUID) -> Void)? = nil

    /// Absolute floor retained for attachment/legacy fixtures. The rendered one-line editor is
    /// taller because TextKit adds the font's real line height to both vertical insets; callers
    /// should use `minimumSingleLineHeight(fontSize:)` for visible composer geometry.
    static let minHeight: CGFloat = 24
    static let maxHeight: CGFloat = 180
    static let textContainerInset = NSSize(width: 5, height: 7)
    private static let minimumSingleLineHeightCache = NSCache<NSNumber, NSNumber>()

    /// The exact stable height of an empty or single-line composer at this text scale. Starting the
    /// SwiftUI frame at the old 24 pt floor made the first typed character grow the editor by about
    /// 7 pt at 110%, which necessarily moved the adjacent bottom-pinned transcript once.
    static func minimumSingleLineHeight(fontSize: CGFloat) -> CGFloat {
        let cacheKey = NSNumber(value: Double(fontSize))
        if let cached = minimumSingleLineHeightCache.object(forKey: cacheKey) {
            return CGFloat(truncating: cached)
        }
        let font = NSFont.systemFont(ofSize: fontSize)
        // TextKit rounds large type sizes differently from raw ascender/descender metrics. Use the
        // same API as the live editor so every supported scale starts at the exact rendered height.
        let textLineHeight = NSLayoutManager().defaultLineHeight(for: font)
        let measured = ceil(textLineHeight + textContainerInset.height * 2)
        let result = min(max(measured, minHeight), maxHeight)
        minimumSingleLineHeightCache.setObject(
            NSNumber(value: Double(result)),
            forKey: cacheKey)
        return result
    }

    /// Text this long or longer pastes as a pill instead of filling the box.
    static let largeTextThreshold = 800

    /// Hidden attribute holding what an attachment expands to on send (image path or
    /// the full pasted text). Present only on attachment characters.
    static let payloadKey = NSAttributedString.Key("mechPayload")
    /// Unique transfer id carried only by a live promised-file placeholder. If the app terminates
    /// first, the placeholder's ordinary payload remains an honest, visible retry message.
    static let pendingFilePromiseKey = NSAttributedString.Key("mechPendingFilePromise")
    static let pendingFilePromisePayloadPrefix =
        "[Attachment is still importing. Drag it again if it does not finish; transfer "

    static func hasSubmittableText(_ draft: String) -> Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !draft.contains(pendingFilePromisePayloadPrefix)
    }

    /// Add a suggested follow-up to whatever is already in the composer. Text the user typed is
    /// theirs, so a suggestion joins it rather than overwriting it. A suggestion is a whole prompt,
    /// so it starts its own line instead of running into the tail of what was typed; a composer
    /// holding only whitespace is treated as empty rather than preserved as a ragged first line.
    static func appending(suggestion: String, to existing: String) -> String {
        guard !existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return suggestion
        }
        return existing.hasSuffix("\n") ? existing + suggestion : existing + "\n" + suggestion
    }

    /// Spoken description of one attached file, matching the transcript chip's wording so the same
    /// attachment is announced identically before and after it is sent.
    static func attachmentAccessibilityLabel(for reference: ConversationFileReference) -> String {
        reference.isMailMessage
            ? "Mail message, \(reference.attachmentDisplayTitle)"
            : "Attached file, \(reference.displayName)"
    }

    /// Spoken description of one composer attachment, derived from its durable payload token.
    ///
    /// The payload is the single value that intake, draft restore, reordering, clipboard, and the
    /// asynchronous appearance re-render all already preserve, so deriving the announcement from it
    /// cannot drift the way a parallel accessibility attribute would.
    static func attachmentAccessibilityLabel(forPayload payload: String) -> String {
        if payload.hasPrefix(pendingFilePromisePayloadPrefix) {
            return "Attachment still importing"
        }
        if let reference = exactFileReference(in: payload) {
            return attachmentAccessibilityLabel(for: reference)
        }
        if let reference = exactArtifactReference(in: payload) {
            let type = reference.type.trimmingCharacters(in: .whitespacesAndNewlines)
            return type.isEmpty
                ? "Artifact, \(reference.title)"
                : "Artifact, \(reference.title), \(type)"
        }
        if let path = exactImagePath(in: payload) {
            return "Attached image, \(URL(fileURLWithPath: path).lastPathComponent)"
        }
        // The legacy chip for a file attached without an owning conversation carries a bare path.
        // Classify by extension rather than by `ImagePathDetector`, which requires the file to be
        // present: a draft whose image has since been moved should still announce as an image.
        if !payload.contains("\n"), payload.hasPrefix("/") {
            let url = URL(fileURLWithPath: payload)
            let isImage = ConversationFileReference.composerImageExtensions
                .contains(url.pathExtension.lowercased())
            return isImage
                ? "Attached image, \(url.lastPathComponent)"
                : "Attached file, \(url.lastPathComponent)"
        }
        return "Pasted text, \(payload.count) characters"
    }

    /// Announcement for the composer as a whole, or nil when nothing is attached.
    ///
    /// This is deliberately a *label* rather than a flattened accessibility value: the value is a
    /// live read/write channel (`setAccessibilityValue` replaces the draft), so substituting spoken
    /// descriptions into it would let any read-modify-write client silently destroy real
    /// attachments and leave their prose behind.
    static func composerAccessibilityLabel(attachmentPayloads: [String]) -> String? {
        guard !attachmentPayloads.isEmpty else { return nil }
        let described = attachmentPayloads.map { attachmentAccessibilityLabel(forPayload: $0) }
        let count = described.count == 1 ? "1 attachment" : "\(described.count) attachments"
        return "Message with \(count): " + described.joined(separator: "; ")
    }

    static func exactFileReference(in payload: String) -> ConversationFileReference? {
        let matches = ConversationFileReference.matches(in: payload)
        guard matches.count == 1,
              matches[0].range == NSRange(location: 0, length: payload.utf16.count)
        else { return nil }
        return matches[0].reference
    }

    static func exactArtifactReference(in payload: String) -> ArtifactDragReference? {
        let matches = ArtifactDragReference.matches(in: payload)
        guard matches.count == 1,
              matches[0].range == NSRange(location: 0, length: payload.utf16.count)
        else { return nil }
        return matches[0].reference
    }

    static func exactImagePath(in payload: String) -> String? {
        let matches = ImagePathDetector.matches(in: payload)
        guard matches.count == 1,
              matches[0].range == NSRange(location: 0, length: payload.utf16.count)
        else { return nil }
        return matches[0].path
    }

    /// Replace exactly one unique pending payload, preserving all edits around it and every other
    /// concurrent placeholder. Returns nil if the user already deleted or submitted that marker.
    static func resolvingPendingFilePromise(
        in draft: String,
        pendingPayload: String,
        replacementPayload: String
    ) -> String? {
        guard pendingPayload.hasPrefix(pendingFilePromisePayloadPrefix),
              let range = draft.range(of: pendingPayload) else { return nil }
        return draft.replacingCharacters(
            in: range,
            with: replacementPayload)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        // scrollableTextView() returns a fully-configured, focusable, editable text
        // view (correct frames/autoresizing + a retained text system) — a hand-assembled
        // one is fragile. Paste is intercepted by overriding paste(_:) on a ComposerTextView
        // subclass installed via object_setClass below.
        let scroll = NSTextView.scrollableTextView()
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        // A real (auto-hidden) vertical scroller makes this the scroll target for the
        // caret, so AppKit stops bubbling scrollRangeToVisible up to the transcript
        // ScrollView — which otherwise nudged it up one line per keystroke.
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.verticalScrollElasticity = .none

        if let tv = scroll.documentView as? NSTextView {
            // Route paste through our attachment logic reliably: a ⌘V event monitor does NOT
            // suppress the default menu paste (it inserted the text twice), but overriding
            // paste(_:) does. ComposerTextView adds no stored properties, so it's safe to install
            // via object_setClass on the view scrollableTextView() built.
            object_setClass(tv, ComposerTextView.self)
            tv.delegate = context.coordinator
            // Force TextKit 1. scrollableTextView() defaults to TextKit 2 on macOS 13+, and TextKit 2
            // does NOT render NSTextAttachment.image — so pasted image thumbnails and text pills are
            // invisible (the attachment IS in the storage, so send still carries the path, which is
            // why it looked like "paste does nothing"). Accessing layoutManager permanently falls back
            // to TextKit 1, where attachments render normally (recalcHeight relies on it too).
            _ = tv.layoutManager
            // Rich text so we can embed image thumbnails and text pills, but typed text
            // stays plain (fixed font/color via typingAttributes).
            tv.isRichText = true
            // Accept image pastes. Without this, NSTextView VALIDATES ⌘V as disabled whenever the
            // clipboard holds ONLY an image (no text) — so paste(_:) is never even called and our
            // image handling never runs (the real reason image paste "did nothing"). importsGraphics
            // enables the paste action; our paste(_:) override then intercepts and inserts the
            // thumbnail itself (returning true), so the default full-size insertion never fires.
            tv.importsGraphics = true
            // Rebuild from ComposerTextView.acceptableDragTypes after every property above that can
            // make NSTextView refresh its native drag policy.
            tv.updateDragTypeRegistration()
            tv.isEditable = true
            tv.isSelectable = true
            tv.allowsUndo = true
            // The composer supplies its own slash/path completion. On macOS 27, allowing the
            // system's remote completion service here can crash the whole app the next time any
            // other window (including Software Update) is ordered onscreen (FB23642313).
            if RemoteTextServiceSafety.isAffectedSystem {
                RemoteTextServiceSafety.disableRemoteCompletion(on: tv)
            }
            tv.font = .systemFont(ofSize: fontSize)
            tv.drawsBackground = false
            tv.textColor = .labelColor
            context.coordinator.startCaretTint()
            // Hand the editor to the window's focus owner as soon as it exists, so a freshly
            // opened window has a preferred responder before it is ever made key.
            focusController?.attach(tv)
            tv.textContainerInset = Self.textContainerInset
            context.coordinator.restoreSerializedContent(text, into: tv)
            context.coordinator.normalizePlainTextAttributes(tv)
            context.coordinator.textView = tv
            context.coordinator.lastSerialized = text
            context.coordinator.observeWidthChanges(scrollView: scroll, textView: tv)
        }
        DispatchQueue.main.async { context.coordinator.recalcHeight() }
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        // Pick up a turn starting or ending immediately, rather than on the next tint tick —
        // but only when it actually changed. This runs on every keystroke, and the tint is
        // otherwise already being resampled on its own timer.
        context.coordinator.refreshCaretTintIfTurnStateChanged(isTurnInFlight)
        guard let tv = nsView.documentView as? NSTextView else { return }
        // Only push the binding into the view when it changed *externally* (cleared after
        // send, or a suggestion loaded) — not as an echo of our own serialize(), which
        // would replace inline attachments with their expanded text.
        if text != context.coordinator.lastSerialized {
            context.coordinator.restoreSerializedContent(text, into: tv)
            context.coordinator.normalizePlainTextAttributes(tv)
            context.coordinator.lastSerialized = text
            DispatchQueue.main.async { context.coordinator.recalcHeight() }
        }
        if tv.font?.pointSize != fontSize {
            tv.font = .systemFont(ofSize: fontSize)
            context.coordinator.normalizePlainTextAttributes(tv)
            DispatchQueue.main.async { context.coordinator.recalcHeight() }
        }
        tv.isEditable = isEnabled
        // Focus is no longer pushed through this update path. `ComposerFocusController` owns it,
        // so the only thing to do here is keep the editor registered as the window's preferred
        // responder across window changes.
        if let tv = context.coordinator.textView,
           context.coordinator.shouldReattachFocus(for: tv) {
            focusController?.attach(tv)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ChatInput
        weak var textView: NSTextView?
        /// The last value we handed to the binding; guards updateNSView from clobbering
        /// attachments with their own serialized form.
        var lastSerialized: String = ""
        /// Last focus-request token acted on (see updateNSView).
        /// Inline autocomplete popover — shared by "/…" commands and "@…" paths.
        private let completion = SlashCompletionController()
        private enum CompletionMode { case none, slash, path }
        private var completionMode: CompletionMode = .none
        /// For @-path mode: the range of the "@token" being replaced and the directory part of
        /// the fragment (so the accepted leaf reassembles the full "@dir/leaf").
        private var pathTokenRange: NSRange?
        private var pathDirPart: String = ""
        private var isNormalizingTextAttributes = false
        private weak var observedScrollView: NSScrollView?
        private var lastObservedComposerWidth: CGFloat?
        private(set) var widthRemeasureRequestCount = 0
        /// Several AppKit frame notifications can arrive before SwiftUI reflects the first height
        /// binding write. Track the queued target so identical passes cannot enqueue the same layout
        /// invalidation repeatedly or let an older measurement overwrite a newer one.
        private var pendingHeight: CGFloat?
        private var caretTint: Timer?
        private var lastTurnInFlight: Bool?
        private weak var focusAttachedWindow: NSWindow?
        /// The system indicator is a stable subview; re-walking the tree per keystroke to find it
        /// was pure waste.
        private weak var cachedInsertionIndicator: NSView?
        private var preparedAttachmentRange: NSRange?
        private struct ActiveAttachmentDrag {
            let descriptor: ComposerAttachmentDragDescriptor
            let sourceRange: NSRange
        }
        private var activeAttachmentDrag: ActiveAttachmentDrag?
        var hasActiveAttachmentDrag: Bool { activeAttachmentDrag != nil }
        /// A focused failure seam for the only stateful clipboard boundary. Production writes
        /// directly to NSPasteboard; tests can prove Cut never deletes before both flavors stick.
        var composerClipboardWriteOverride:
            ((NSPasteboard, String, Data) -> Bool)?

        init(_ parent: ChatInput) {
            self.parent = parent
            super.init()
            completion.onAccept = { [weak self] in self?.acceptCompletion() }
        }

        deinit {
            if let nonce = activeAttachmentDrag?.descriptor.nonce {
                Task { @MainActor in
                    ComposerAttachmentDragRegistry.retire(nonce)
                }
            }
            NotificationCenter.default.removeObserver(self)
            caretTint?.invalidate()
        }

        /// The caret is an AppKit-owned `NSTextInsertionIndicator`, so the tint has to be pushed to
        /// it rather than drawn. Resampling on a timer is what lets the hue drift with the activity
        /// outline instead of being fixed at setup.
        func startCaretTint() {
            caretTint?.invalidate()
            let timer = Timer(
                timeInterval: ComposerCaret.refreshInterval, repeats: true
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.refreshCaretTint()
                }
            }
            // `.common` so the drift keeps running while the user scrolls or holds a menu open.
            RunLoop.main.add(timer, forMode: .common)
            caretTint = timer
            refreshCaretTint()
        }

        func refreshCaretTintIfTurnStateChanged(_ inFlight: Bool) {
            guard lastTurnInFlight != inFlight else { return }
            lastTurnInFlight = inFlight
            refreshCaretTint()
        }

        /// `initialFirstResponder` only needs setting when the editor lands in a new window.
        func shouldReattachFocus(for textView: NSTextView) -> Bool {
            guard focusAttachedWindow !== textView.window else { return false }
            focusAttachedWindow = textView.window
            return true
        }

        func refreshCaretTint() {
            guard let textView else { return }
            let workspace = NSWorkspace.shared
            let increaseContrast = workspace.accessibilityDisplayShouldIncreaseContrast
            let isDark = textView.effectiveAppearance
                .bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let tint = ComposerCaret.color(
                driftPhase: ComposerCaret.driftPhase(
                    at: CACurrentMediaTime(),
                    reduceMotion: workspace.accessibilityDisplayShouldReduceMotion),
                isDark: isDark,
                inFlight: parent.isTurnInFlight,
                increaseContrast: increaseContrast)
            textView.insertionPointColor = tint
            applyCaretGlow(
                tint: tint,
                in: textView,
                opacity: ComposerCaret.glowOpacity(
                    increaseContrast: increaseContrast,
                    reduceTransparency: workspace.accessibilityDisplayShouldReduceTransparency))
        }

        /// The caret is an AppKit-owned `NSTextInsertionIndicator`, so the bloom is attached to that
        /// view's layer. Re-applied on each tick because the indicator is the system's to recreate,
        /// and because the shadow has to follow the drifting hue.
        func applyCaretGlow(tint: NSColor, in textView: NSTextView, opacity: Float) {
            let found = cachedInsertionIndicator?.superview != nil
                ? cachedInsertionIndicator
                : Self.insertionIndicator(in: textView)
            guard let indicator = found else { return }
            cachedInsertionIndicator = indicator
            indicator.wantsLayer = true
            guard let layer = indicator.layer else { return }
            layer.masksToBounds = false
            // `ComposerCaret.color` is currently a concrete appearance-specific sRGB value, but
            // resolve through the same layer boundary as dynamic palette colors so a future
            // semantic caret tint cannot be frozen against the wrong window appearance.
            layer.shadowColor = tint.mechanicianCGColor(
                in: textView.effectiveAppearance,
                alpha: 1)
            layer.shadowRadius = ComposerCaret.glowRadius
            layer.shadowOpacity = opacity
            layer.shadowOffset = .zero
            // Derived from the caret's own alpha channel, so the bloom matches whatever shape
            // AppKit decided to draw.
            layer.shadowPath = nil
        }

        static func insertionIndicator(in view: NSView) -> NSView? {
            for subview in view.subviews {
                if subview is NSTextInsertionIndicator { return subview }
                if let nested = insertionIndicator(in: subview) { return nested }
            }
            return nil
        }

        func observeWidthChanges(scrollView: NSScrollView, textView: NSTextView) {
            guard observedScrollView !== scrollView else { return }
            NotificationCenter.default.removeObserver(self)
            observedScrollView = scrollView
            lastObservedComposerWidth = scrollView.contentView.bounds.width
            scrollView.postsFrameChangedNotifications = true
            scrollView.contentView.postsFrameChangedNotifications = true
            textView.postsFrameChangedNotifications = true
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(composerWidthDidChange(_:)),
                name: NSView.frameDidChangeNotification,
                object: scrollView)
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(composerWidthDidChange(_:)),
                name: NSView.frameDidChangeNotification,
                object: scrollView.contentView)
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(composerWidthDidChange(_:)),
                name: NSView.frameDidChangeNotification,
                object: textView)
        }

        @objc private func composerWidthDidChange(_ notification: Notification) {
            guard let scrollView = observedScrollView else { return }
            let width = scrollView.contentView.bounds.width
            guard width > 0 else { return }
            if let previous = lastObservedComposerWidth,
               abs(previous - width) <= 0.5 {
                return
            }
            lastObservedComposerWidth = width
            widthRemeasureRequestCount += 1
            // AppKit updates the clip view, text container, and glyph layout on adjacent run-loop
            // passes when the inspector opens. Measure after those passes so wrapped text grows the
            // composer instead of being clipped inside its old one-line height.
            DispatchQueue.main.async { [weak self] in
                self?.recalcHeight(invalidateLayout: true)
                DispatchQueue.main.async { [weak self] in
                    self?.recalcHeight(invalidateLayout: true)
                }
            }
        }

        func applyTypingAttributes(_ tv: NSTextView) {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: parent.fontSize),
                .foregroundColor: NSColor.labelColor,
            ]
            tv.typingAttributes = attributes
            tv.textColor = .labelColor
        }

        /// The composer is intentionally plain text plus attachment markers. NSTextView can inherit
        /// an attachment's empty/default typing run when the caret moves immediately before it; in
        /// dark mode that default is black. Give every ordinary character explicit dynamic label
        /// styling while preserving attachment and hidden payload attributes.
        func normalizePlainTextAttributes(_ tv: NSTextView) {
            guard !isNormalizingTextAttributes, let storage = tv.textStorage else {
                applyTypingAttributes(tv)
                return
            }
            isNormalizingTextAttributes = true
            defer { isNormalizingTextAttributes = false }

            let fullRange = NSRange(location: 0, length: storage.length)
            var textRanges: [NSRange] = []
            storage.enumerateAttribute(.attachment, in: fullRange) { attachment, range, _ in
                if attachment == nil { textRanges.append(range) }
            }
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: parent.fontSize),
                .foregroundColor: NSColor.labelColor,
            ]
            storage.beginEditing()
            for range in textRanges { storage.addAttributes(attributes, range: range) }
            storage.endEditing()
            applyTypingAttributes(tv)
        }

        /// Called from ComposerTextView.paste(_:). Returns true when we handled the paste (image,
        /// large-text pill, or forced-plain small text) so the default paste is skipped — which is
        /// what stops the text being inserted twice.
        func handlePaste(into tv: NSTextView) -> Bool {
            handlePaste(from: .general, into: tv)
        }

        /// Pasteboard injection keeps the ordered private clipboard path testable without mutating
        /// the user's system clipboard.
        func handlePaste(from pasteboard: NSPasteboard, into tv: NSTextView) -> Bool {
            attachFromPasteboard(pasteboard, into: tv)
        }

        /// Ordinary plain-text paste carrying a raw attachment token.
        ///
        /// This runs after `handlePaste`, so it only sees text that was not a recognised composer
        /// payload — which is the point. Every path by which this app puts a draft on the pasteboard
        /// projects tokens to labels first (`publicText(forDraggedAttachment:)` for a single token,
        /// `ComposerTokenScrub.publicText` for a multi-segment copy), so a raw token in the public
        /// string did not come from us. `ConversationFileReference.matches` decodes tokens with no
        /// signature, and the draft is re-scanned for them later, so inserting the text verbatim
        /// would let whoever wrote it choose an attachment reference in the user's composer.
        ///
        /// The forged reference resolves against the current conversation's own storage, so the
        /// blast radius is that conversation's media rather than the filesystem. Closed anyway: a
        /// reference nobody in this app created has no business surviving a paste.
        ///
        /// Image paths are deliberately left alone. They render locally and never travel as bytes,
        /// and pasting a path to a screenshot to see it inline is a real thing people do.
        @discardableResult
        func handleForgedTokenPaste(
            from pasteboard: NSPasteboard = .general,
            into tv: NSTextView
        ) -> Bool {
            guard let text = pasteboard.string(forType: .string),
                  ComposerTokenScrub.containsAttachmentToken(text) else { return false }
            insertPlain(ComposerTokenScrub.neutralizingForgedTokens(text), into: tv)
            return true
        }

        func canHandleDrop(from pasteboard: NSPasteboard) -> Bool {
            // During drag-enter, an NSItemProvider representation may be advertised but not loaded
            // yet. Inspect type availability here; decode/read the payload only after the drop.
            if pasteboard.availableType(
                from: [
                    ComposerAttachmentDragDescriptor.pasteboardType,
                    ArtifactActions.referencePasteboardType,
                ]) != nil {
                return true
            }
            if pasteboard.availableType(
                from: ConversationFilePromiseMaterializer.readablePasteboardTypes) != nil {
                return true
            }
            if MailMessageDragReceiver.canRead(from: pasteboard) {
                return true
            }
            return pasteboard.canReadObject(
                forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true])
        }

        func dropOperation(for pasteboard: NSPasteboard) -> NSDragOperation {
            guard let descriptor = composerAttachmentDescriptor(from: pasteboard),
                  descriptor.isTrustedForCurrentProcess,
                  ComposerAttachmentDragRegistry.contains(descriptor.nonce),
                  pasteboard.string(forType: .string)
                    == publicText(forDraggedAttachment: descriptor.payload),
                  descriptor.nonce == activeAttachmentDrag?.descriptor.nonce else {
                return .copy
            }
            return .move
        }

        /// Kept as a compatibility-shaped entry point for focused tests and paste handling.
        func canHandleFileDrop(from pasteboard: NSPasteboard) -> Bool {
            canHandleDrop(from: pasteboard)
        }

        /// Prefer the app-private artifact representation. If SwiftUI/AppKit resolved only its
        /// public file URL, recover the reference from the live export registry. Ordinary Finder
        /// files retain the existing thumbnail/file-chip behavior.
        @discardableResult
        func handleDrop(
            from pasteboard: NSPasteboard,
            into tv: NSTextView,
            insertionIndex: Int? = nil
        ) -> Bool {
            let safeInsertionIndex = min(
                max(insertionIndex ?? tv.selectedRange().location, 0),
                tv.textStorage?.length ?? tv.string.utf16.count)
            if let descriptor = composerAttachmentDescriptor(from: pasteboard) {
                let visibleText = pasteboard.string(forType: .string)
                guard descriptor.isTrustedForCurrentProcess,
                      ComposerAttachmentDragRegistry.contains(descriptor.nonce),
                      visibleText == publicText(
                        forDraggedAttachment: descriptor.payload) else {
                    // Authentication alone does not provide freshness: another process can capture
                    // ciphertext from an earlier drag and replay it while this app remains open.
                    // Only a currently registered source session with its exact visible projection
                    // may contribute hidden payload. Consume every other private descriptor so
                    // AppKit cannot fall through to a different hidden/native representation.
                    guard let visibleText else { return true }
                    tv.setSelectedRange(NSRange(location: safeInsertionIndex, length: 0))
                    insertPlain(visibleText, into: tv)
                    return true
                }
                return handleComposerAttachmentDrop(
                    descriptor,
                    into: tv,
                    insertionIndex: safeInsertionIndex)
            }
            if pasteboard.availableType(
                from: [ComposerAttachmentDragDescriptor.pasteboardType]) != nil,
               let publicText = pasteboard.string(forType: .string) {
                // Oversized/malformed private data is rejected before decoding. Preserve only the
                // visible representation, just as for a well-formed descriptor with a bad HMAC.
                tv.setSelectedRange(NSRange(
                    location: safeInsertionIndex,
                    length: 0))
                insertPlain(publicText, into: tv)
                return true
            }
            if pasteboard.availableType(
                from: [ComposerAttachmentDragDescriptor.pasteboardType]) != nil {
                // A malformed private descriptor with no public string is still ours to consume.
                // Returning false would let NSTextView try a secondary hidden representation.
                return true
            }

            tv.setSelectedRange(NSRange(location: safeInsertionIndex, length: 0))
            // AppKit explicitly requires promised-file receivers to be handled before URL fallback:
            // Mail and similar apps may advertise both while only the promise can materialize bytes.
            let promiseReceivers = ConversationFilePromiseMaterializer.receivers(
                from: pasteboard)
            if !promiseReceivers.isEmpty {
                return handleFilePromiseDrop(
                    promiseReceivers.map {
                        $0 as ConversationFilePromiseReceiving
                    },
                    into: tv)
            }
            let mailReceivers = MailMessageDragReceiver.receivers(from: pasteboard)
            if !mailReceivers.isEmpty {
                return handleFilePromiseDrop(
                    mailReceivers.map {
                        $0 as ConversationFilePromiseReceiving
                    },
                    into: tv)
            }

            let directReferences = ArtifactActions.references(from: pasteboard)
            if !directReferences.isEmpty {
                var budget = ConversationAttachmentImportBudget()
                for reference in directReferences {
                    guard budget.beginAttachment() != nil else {
                        if let message = budget.takeLimitMessage() {
                            insertPlain(message, into: tv)
                        }
                        break
                    }
                    insertArtifactReference(reference, into: tv)
                }
                return true
            }
            if pasteboard.availableType(
                from: [ArtifactActions.referencePasteboardType]) != nil,
               let publicText = pasteboard.string(forType: .string) {
                // A custom artifact UTI is not proof of app provenance. Invalid/oversized private
                // metadata can contribute only the public text the user could already see.
                insertPlain(publicText, into: tv)
                return true
            }

            let urls = fileURLs(from: pasteboard)
                .filter { FileManager.default.fileExists(atPath: $0.path) }
            guard !urls.isEmpty else { return false }
            var budget = ConversationAttachmentImportBudget()
            for url in urls {
                guard let maximumBytes = budget.beginAttachment() else {
                    if let message = budget.takeLimitMessage() {
                        insertPlain(message, into: tv)
                    }
                    break
                }
                let intake = ConversationAttachmentIntake.ingest(
                    url,
                    conversationID: parent.conversationID,
                    maximumBytes: maximumBytes,
                    store: parent.attachmentStore)
                budget.recordCommittedBytes(intake.committedByteCount)
                switch intake {
                case .artifact(let reference):
                    insertArtifactReference(reference, into: tv)
                case .image(let url, let image):
                    insertImageAttachment(image, path: url.path, into: tv)
                case .file(let reference, let ownedURL):
                    insertFileReference(reference, url: ownedURL, into: tv)
                case .externalFile(let url):
                    // An isolated/test composer has no durable owner. Preserve the legacy path chip
                    // instead of writing test files into the process-wide conversation store.
                    insertFileChip(url, into: tv)
                case .unavailable(let displayName):
                    insertPlain(
                        "[Attachment unavailable: \(displayName)]",
                        into: tv)
                }
            }
            return true
        }

        private struct PendingFilePromiseSlot {
            let receiverIndex: Int
            let transferID: String
            let fallbackPayload: String
        }

        private enum PromisedPiece {
            case attachment(NSTextAttachment, payload: String)
            case message(String)

            var serialized: String {
                switch self {
                case .attachment(_, let payload): return payload
                case .message(let message): return message
                }
            }
        }

        private struct PromisedReplacement {
            let attributed: NSAttributedString
            let serialized: String
            let artifactReferences: [ArtifactDragReference]
            /// Every URL here was minted by this fulfillment. If the durable marker loses a final
            /// race, these bytes can be removed without touching pre-existing conversation media.
            let ownedURLs: [URL]
        }

        /// Insert one stable placeholder per receiver at the authored drop point, then materialize
        /// asynchronously. A legacy receiver may yield several files; they replace its one slot in
        /// promised-filename order without disturbing text typed while the producer was working.
        func handleFilePromiseDrop(
            _ receivers: [ConversationFilePromiseReceiving],
            into tv: NSTextView
        ) -> Bool {
            let originalConversationID = parent.conversationID
            let attachmentStore = parent.attachmentStore
            var acceptedReceivers: [ConversationFilePromiseReceiving] = []
            var slots: [PendingFilePromiseSlot] = []
            var budget = ConversationAttachmentImportBudget()

            for receiver in receivers.prefix(
                ConversationAttachmentImportBudget.maximumFiles
            ) {
                let transferID = UUID().uuidString
                let fallback = ChatInput.pendingFilePromisePayloadPrefix
                    + "\(transferID)]"
                let slot = PendingFilePromiseSlot(
                    receiverIndex: slots.count,
                    transferID: transferID,
                    fallbackPayload: fallback)
                guard insertAttachment(
                    pendingFilePromiseAttachment(),
                    payload: fallback,
                    additionalAttributes: [
                        ChatInput.pendingFilePromiseKey: transferID,
                    ],
                    into: tv)
                else { continue }
                acceptedReceivers.append(receiver)
                slots.append(slot)
            }
            guard !acceptedReceivers.isEmpty else { return false }
            if receivers.count > ConversationAttachmentImportBudget.maximumFiles,
               let message = budget.takeLimitMessage() {
                insertPlain(message, into: tv)
            }

            if let originalConversationID {
                parent.onPromisedAttachmentTransferBegan?(originalConversationID)
            }
            let finishTransfer = parent.onPromisedAttachmentTransferEnded

            ConversationFilePromiseMaterializer.materialize(
                acceptedReceivers
            ) { [weak self, weak tv] outcomes in
                defer {
                    if let originalConversationID {
                        finishTransfer?(originalConversationID)
                    }
                }
                guard let self else { return }
                for slot in slots {
                    let receiverOutcomes = outcomes.filter {
                        $0.receiverIndex == slot.receiverIndex
                    }
                    let isOriginalConversationLive =
                        self.parent.conversationID == originalConversationID
                    let store = attachmentStore ?? ConversationStore.shared
                    if let originalConversationID,
                       !store.contains(originalConversationID) {
                        if isOriginalConversationLive, let tv {
                            _ = self.replacePendingFilePromise(
                                slot,
                                with: NSAttributedString(
                                    string:
                                        "[Attachment unavailable. The conversation was removed]",
                                    attributes: self.plainTextAttributes),
                                in: tv)
                        }
                        continue
                    }
                    if isOriginalConversationLive {
                        guard let tv,
                              self.pendingFilePromiseRange(
                                  for: slot,
                                  in: tv) != nil else {
                            // Deleted/cleared placeholders are cancellation. Avoid copying promised
                            // bytes into an orphaned conversation-media directory.
                            continue
                        }
                    } else if let originalConversationID {
                        // The native editor no longer owns this draft. Validate its exact durable
                        // marker before any promised bytes are copied into conversation media.
                        guard self.parent.canResolvePromisedAttachment?(
                            originalConversationID,
                            slot.fallbackPayload) == true else { continue }
                    }
                    let replacement = self.promisedReplacement(
                        for: receiverOutcomes,
                        originalConversationID: originalConversationID,
                        attachmentStore: attachmentStore,
                        textView: tv,
                        budget: &budget)

                    if isOriginalConversationLive,
                       let tv,
                       self.replacePendingFilePromise(
                           slot,
                           with: replacement.attributed,
                           in: tv) {
                        for reference in replacement.artifactReferences {
                            self.parent.onArtifactReference?(reference)
                        }
                    } else if let originalConversationID,
                              self.parent.conversationID != originalConversationID {
                        let resolved = self.parent.onPromisedAttachmentResolution?(
                            originalConversationID,
                            slot.fallbackPayload,
                            replacement.serialized) == true
                        if !resolved {
                            self.removeUncommittedPromisedFiles(replacement.ownedURLs)
                        }
                    } else {
                        self.removeUncommittedPromisedFiles(replacement.ownedURLs)
                    }
                }
            }
            return true
        }

        private func promisedReplacement(
            for outcomes: [ConversationFilePromiseOutcome],
            originalConversationID: UUID?,
            attachmentStore: ConversationStore?,
            textView: NSTextView?,
            budget: inout ConversationAttachmentImportBudget
        ) -> PromisedReplacement {
            var pieces: [PromisedPiece] = []
            var artifactReferences: [ArtifactDragReference] = []
            var ownedURLs: [URL] = []
            let resolvedOutcomes: [ConversationFilePromiseOutcome]
            if outcomes.isEmpty {
                resolvedOutcomes = []
                pieces.append(.message(
                    "[Attachment unavailable. The source app returned no promised file]"))
            } else {
                resolvedOutcomes = outcomes
            }

            for outcome in resolvedOutcomes {
                guard let maximumBytes = budget.beginAttachment() else {
                    if let message = budget.takeLimitMessage() {
                        pieces.append(.message(message))
                    }
                    break
                }
                switch outcome.result {
                case .success(let stagedURL):
                    let intake = ConversationAttachmentIntake.ingest(
                        stagedURL,
                        conversationID: originalConversationID,
                        sourceIsEphemeral: true,
                        maximumBytes: maximumBytes,
                        store: attachmentStore)
                    budget.recordCommittedBytes(intake.committedByteCount)
                    switch intake {
                    case .artifact(let reference):
                        artifactReferences.append(reference)
                        pieces.append(.attachment(
                            artifactAttachment(for: reference),
                            payload: reference.promptToken))
                    case .image(let ownedURL, let image):
                        ownedURLs.append(ownedURL)
                        let attachment = NSTextAttachment()
                        let thumbnail = Self.thumbnail(image)
                        attachment.image = thumbnail
                        attachment.bounds = CGRect(
                            origin: .zero,
                            size: thumbnail.size)
                        pieces.append(.attachment(
                            attachment,
                            payload: ownedURL.path))
                    case .file(let reference, let ownedURL):
                        ownedURLs.append(ownedURL)
                        pieces.append(.attachment(
                            fileAttachment(
                                for: reference,
                                url: ownedURL,
                                in: textView),
                            payload: reference.promptToken))
                    case .externalFile:
                        pieces.append(.message(
                            "[Attachment unavailable. Promised files require a conversation]"))
                    case .unavailable(let displayName):
                        pieces.append(.message(
                            "[Attachment unavailable: \(safePromisedFileName(displayName))]"))
                    }
                case .failure:
                    let name = safePromisedFileName(
                        outcome.suggestedFileName ?? "dropped file")
                    pieces.append(.message(
                        "[Attachment unavailable: \(name). The source app could not provide it]"))
                }
            }

            let attributed = NSMutableAttributedString()
            for (index, piece) in pieces.enumerated() {
                if index > 0 {
                    attributed.append(NSAttributedString(
                        string: " ",
                        attributes: plainTextAttributes))
                }
                switch piece {
                case .attachment(let attachment, let payload):
                    attributed.append(attachmentPiece(
                        attachment,
                        payload: payload,
                        additionalAttributes: [:]))
                case .message(let message):
                    attributed.append(NSAttributedString(
                        string: message,
                        attributes: plainTextAttributes))
                }
            }
            return PromisedReplacement(
                attributed: attributed,
                serialized: pieces.map(\.serialized).joined(separator: " "),
                artifactReferences: artifactReferences,
                ownedURLs: ownedURLs)
        }

        private func removeUncommittedPromisedFiles(_ urls: [URL]) {
            for url in urls {
                try? FileManager.default.removeItem(at: url)
            }
        }

        private func replacePendingFilePromise(
            _ slot: PendingFilePromiseSlot,
            with replacement: NSAttributedString,
            in tv: NSTextView
        ) -> Bool {
            guard let storage = tv.textStorage,
                  let markerRange = pendingFilePromiseRange(
                      for: slot,
                      in: tv) else { return false }
            guard tv.shouldChangeText(
                in: markerRange,
                replacementString: nil) else { return false }
            var selection = tv.selectedRange()
            let delta = replacement.length - markerRange.length
            if selection.location >= NSMaxRange(markerRange) {
                selection.location = max(0, selection.location + delta)
            } else if NSIntersectionRange(selection, markerRange).length > 0 {
                selection = NSRange(
                    location: markerRange.location + replacement.length,
                    length: 0)
            }
            // Fulfillment is the completion of the original drop, not a new user edit. Registering
            // it as undoable would let Undo resurrect a dead "Importing…" marker with no producer.
            let undoManager = tv.composerUndoManager
            undoManager?.disableUndoRegistration()
            storage.replaceCharacters(in: markerRange, with: replacement)
            tv.setSelectedRange(selection)
            tv.didChangeText()
            undoManager?.enableUndoRegistration()
            normalizePlainTextAttributes(tv)
            syncFromTextView()
            return true
        }

        private func pendingFilePromiseRange(
            for slot: PendingFilePromiseSlot,
            in tv: NSTextView
        ) -> NSRange? {
            guard let storage = tv.textStorage else { return nil }
            let fullRange = NSRange(location: 0, length: storage.length)
            var markerRange: NSRange?
            storage.enumerateAttribute(
                .attachment,
                in: fullRange
            ) { attachment, range, stop in
                if attachment != nil,
                   storage.attribute(
                       ChatInput.pendingFilePromiseKey,
                       at: range.location,
                       effectiveRange: nil) as? String == slot.transferID {
                    markerRange = range
                    stop.pointee = true
                }
            }
            // Switching away and back reconstructs the honest fallback as ordinary text. If the
            // exact unique payload is still present, it remains safe to resolve in place.
            if markerRange == nil {
                let range = (storage.string as NSString).range(
                    of: slot.fallbackPayload)
                if range.location != NSNotFound { markerRange = range }
            }
            return markerRange
        }

        private func pendingFilePromiseAttachment() -> NSTextAttachment {
            let font = NSFont.systemFont(ofSize: parent.fontSize)
            let image = Self.pillImage("⏳ Importing dropped file…", font: font)
            let attachment = NSTextAttachment()
            attachment.image = image
            attachment.bounds = CGRect(
                x: 0,
                y: font.descender,
                width: image.size.width,
                height: image.size.height)
            return attachment
        }

        private func safePromisedFileName(_ candidate: String) -> String {
            let leaf = URL(fileURLWithPath: candidate).lastPathComponent
            let cleaned = leaf.unicodeScalars.map { scalar -> Character in
                scalar.value < 0x20 || scalar.value == 0x7F
                    ? " "
                    : Character(scalar)
            }
            .reduce(into: "") { $0.append($1) }
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            return cleaned.isEmpty ? "dropped file" : String(cleaned.prefix(120))
        }

        // MARK: Attachment token dragging

        /// Stage a drag only when the pointer is truly inside an attachment's glyph. Using the
        /// nearest insertion index alone would make a drag that begins in adjacent prose steal the
        /// neighboring chip.
        func prepareAttachmentDrag(at point: NSPoint, in tv: NSTextView) -> Bool {
            preparedAttachmentRange = nil
            guard tv.isEditable,
                  let range = attachmentRange(at: point, in: tv),
                  let storage = tv.textStorage,
                  storage.attribute(
                    ChatInput.payloadKey,
                    at: range.location,
                    effectiveRange: nil) is String,
                  storage.attribute(
                    ChatInput.pendingFilePromiseKey,
                    at: range.location,
                    effectiveRange: nil) == nil else { return false }
            preparedAttachmentRange = range
            tv.setSelectedRange(range)
            return true
        }

        @discardableResult
        func cancelPreparedAttachmentDrag() -> Bool {
            guard preparedAttachmentRange != nil else { return false }
            preparedAttachmentRange = nil
            return true
        }

        @discardableResult
        func beginPreparedAttachmentDrag(from tv: NSTextView, event: NSEvent) -> Bool {
            guard let sourceRange = preparedAttachmentRange,
                  let storage = tv.textStorage,
                  NSMaxRange(sourceRange) <= storage.length,
                  let payload = storage.attribute(
                    ChatInput.payloadKey,
                    at: sourceRange.location,
                    effectiveRange: nil) as? String else { return false }
            preparedAttachmentRange = nil

            let descriptor = ComposerAttachmentDragDescriptor(
                nonce: UUID(),
                payload: payload,
                sourceConversationID: parent.conversationID)
            guard let data = descriptor.processSignedEncodedData else { return false }
            let pasteboardItem = NSPasteboardItem()
            pasteboardItem.setData(
                data,
                forType: ComposerAttachmentDragDescriptor.pasteboardType)
            pasteboardItem.setString(
                publicText(forDraggedAttachment: payload),
                forType: .string)
            addNativeRepresentations(
                for: payload,
                to: pasteboardItem,
                sourceConversationID: parent.conversationID)

            let draggingItem = NSDraggingItem(pasteboardWriter: pasteboardItem)
            let attachment = storage.attribute(
                .attachment,
                at: sourceRange.location,
                effectiveRange: nil) as? NSTextAttachment
            let frame = attachmentFrame(for: sourceRange, in: tv)
            draggingItem.setDraggingFrame(
                frame,
                contents: Self.dragImage(for: attachment, frame: frame, in: tv))

            activeAttachmentDrag = ActiveAttachmentDrag(
                descriptor: descriptor,
                sourceRange: sourceRange)
            let session = tv.beginDraggingSession(
                with: [draggingItem],
                event: event,
                source: tv)
            ComposerAttachmentDragRegistry.register(descriptor.nonce)
            session.animatesToStartingPositionsOnCancelOrFail = true
            return true
        }

        /// A drag preview AppKit can actually encode.
        ///
        /// `NSImage(size:)` creates an image with **no representations**, and AppKit encodes the
        /// dragging item's contents as PNG. Measured on a real drag: 147 log lines of
        /// "CGImageDestinationFinalize was called, but there were no images added", one every few
        /// milliseconds for the whole gesture, and a session with nothing under the pointer. A file
        /// chip's attachment draws through its cell rather than an `image`, so the nil branch is the
        /// ordinary case, not an edge case.
        ///
        /// Snapshotting the glyph out of the text view also gives the honest preview: what you picked
        /// up looks like what was sitting in the composer.
        static func dragImage(
            for attachment: NSTextAttachment?,
            frame: NSRect,
            in tv: NSTextView
        ) -> NSImage {
            if let image = attachment?.image, !image.representations.isEmpty {
                return image
            }
            let size = NSSize(width: max(1, frame.width), height: max(1, frame.height))
            if let snapshot = tv.bitmapImageRepForCachingDisplay(in: frame) {
                tv.cacheDisplay(in: frame, to: snapshot)
                let rendered = NSImage(size: size)
                rendered.addRepresentation(snapshot)
                return rendered
            }
            // Last resort: still a real bitmap, because an empty one is what caused the errors.
            let placeholder = NSImage(size: size)
            placeholder.lockFocus()
            NSColor.secondaryLabelColor.withAlphaComponent(0.25).setFill()
            NSRect(origin: .zero, size: size).fill()
            placeholder.unlockFocus()
            return placeholder
        }

        func finishAttachmentDrag() {
            preparedAttachmentRange = nil
            if let nonce = activeAttachmentDrag?.descriptor.nonce {
                ComposerAttachmentDragRegistry.retire(nonce)
            }
            activeAttachmentDrag = nil
        }

        private func attachmentRange(at point: NSPoint, in tv: NSTextView) -> NSRange? {
            guard let layoutManager = tv.layoutManager,
                  let textContainer = tv.textContainer,
                  let storage = tv.textStorage,
                  storage.length > 0 else { return nil }
            let containerPoint = NSPoint(
                x: point.x - tv.textContainerOrigin.x,
                y: point.y - tv.textContainerOrigin.y)
            var fraction: CGFloat = 0
            let glyphIndex = layoutManager.glyphIndex(
                for: containerPoint,
                in: textContainer,
                fractionOfDistanceThroughGlyph: &fraction)
            guard glyphIndex < layoutManager.numberOfGlyphs else { return nil }
            let characterIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
            guard let range = ComposerAttachmentReordering.attachmentRange(
                at: characterIndex,
                in: storage) else { return nil }
            let frame = attachmentFrame(for: range, in: tv).insetBy(dx: -2, dy: -2)
            return frame.contains(point) ? range : nil
        }

        private func attachmentFrame(for range: NSRange, in tv: NSTextView) -> NSRect {
            guard let layoutManager = tv.layoutManager,
                  let textContainer = tv.textContainer else {
                return NSRect(x: tv.textContainerOrigin.x, y: tv.textContainerOrigin.y,
                              width: 1, height: 1)
            }
            let glyphRange = layoutManager.glyphRange(
                forCharacterRange: range,
                actualCharacterRange: nil)
            let frame = layoutManager.boundingRect(
                forGlyphRange: glyphRange,
                in: textContainer)
                .offsetBy(dx: tv.textContainerOrigin.x, dy: tv.textContainerOrigin.y)
            return NSRect(
                x: frame.minX,
                y: frame.minY,
                width: max(frame.width, 1),
                height: max(frame.height, 1))
        }

        private func composerAttachmentDescriptor(
            from pasteboard: NSPasteboard
        ) -> ComposerAttachmentDragDescriptor? {
            for item in (pasteboard.pasteboardItems ?? [])
                .prefix(ConversationAttachmentImportBudget.maximumFiles) {
                guard let itemData = item.data(
                    forType: ComposerAttachmentDragDescriptor.pasteboardType),
                      let descriptor = ComposerAttachmentDragDescriptor.decodeProcessPrivate(
                        itemData)
                else { continue }
                return descriptor
            }
            return ComposerAttachmentDragDescriptor.decodeProcessPrivate(
                pasteboard.data(forType: ComposerAttachmentDragDescriptor.pasteboardType))
        }

        private func handleComposerAttachmentDrop(
            _ descriptor: ComposerAttachmentDragDescriptor,
            into tv: NSTextView,
            insertionIndex: Int
        ) -> Bool {
            guard descriptor.isTrustedForCurrentProcess else { return false }
            if descriptor.nonce == activeAttachmentDrag?.descriptor.nonce,
               let sourceRange = activeAttachmentDrag?.sourceRange {
                // Dropping on either edge of the source is a valid idempotent move. Consume it
                // here; returning false would let NSTextView insert the descriptor's public string
                // fallback and duplicate the payload that is already present.
                guard insertionIndex < sourceRange.location
                        || insertionIndex > NSMaxRange(sourceRange) else {
                    tv.setSelectedRange(sourceRange)
                    return true
                }
                _ = moveAttachment(
                    in: tv,
                    attachmentRange: sourceRange,
                    to: insertionIndex)
                // A stale/invalid source must cancel safely rather than fall through to AppKit's
                // string/file representation and turn one attachment into two.
                return true
            }
            return copyDraggedAttachment(descriptor, into: tv, at: insertionIndex)
        }

        /// Apply a same-composer move as one attributed edit. The moved substring includes every
        /// token attribute but excludes neighboring whitespace, so no payload can be duplicated or
        /// dropped and visual order remains serialized/provider order.
        @discardableResult
        func moveAttachment(
            in tv: NSTextView,
            attachmentRange sourceRange: NSRange,
            to insertionIndex: Int
        ) -> Bool {
            guard let storage = tv.textStorage,
                  let move = ComposerAttachmentReordering.move(
                    in: storage,
                    attachmentRange: sourceRange,
                    to: insertionIndex) else { return false }
            replaceComposerContent(
                in: tv,
                with: move.content,
                selection: move.selection,
                actionName: String(localized: "Move Attachment"))
            return true
        }

        private func replaceComposerContent(
            in tv: NSTextView,
            with content: NSAttributedString,
            selection: NSRange,
            actionName: String
        ) {
            guard let storage = tv.textStorage else { return }
            let previous = NSAttributedString(attributedString: storage)
            let previousSelection = tv.selectedRange()
            let fullRange = NSRange(location: 0, length: storage.length)
            guard tv.shouldChangeText(in: fullRange, replacementString: nil) else { return }

            tv.composerUndoManager?.registerUndo(withTarget: self) { [weak tv] coordinator in
                guard let tv else { return }
                coordinator.replaceComposerContent(
                    in: tv,
                    with: previous,
                    selection: previousSelection,
                    actionName: actionName)
            }
            tv.composerUndoManager?.setActionName(actionName)
            storage.setAttributedString(content)
            tv.setSelectedRange(selection)
            tv.didChangeText()
        }

        private func copyDraggedAttachment(
            _ descriptor: ComposerAttachmentDragDescriptor,
            into tv: NSTextView,
            at insertionIndex: Int
        ) -> Bool {
            tv.setSelectedRange(NSRange(location: insertionIndex, length: 0))
            var payload = descriptor.payload
            if let sourceConversationID = descriptor.sourceConversationID,
               let destinationConversationID = parent.conversationID,
               sourceConversationID != destinationConversationID {
                payload = (parent.attachmentStore ?? ConversationStore.shared)
                    .cloneComposerMediaPaths(
                    in: payload,
                    from: sourceConversationID,
                    to: destinationConversationID)
            }

            if let reference = exactArtifactReference(in: payload) {
                insertArtifactReference(reference, into: tv)
                return true
            }
            if let reference = exactFileReference(in: payload),
               let conversationID = parent.conversationID,
               let url = (parent.attachmentStore ?? ConversationStore.shared)
                .composerFileURL(
                    conversationID: conversationID,
                    reference: reference) {
                insertFileReference(reference, url: url, into: tv)
                return true
            }
            if let path = exactImagePath(in: payload),
               let image = NSImage(contentsOfFile: path) {
                insertImageAttachment(image, path: path, into: tv)
                return true
            }

            // Text-pill and legacy file-chip drags still retain their exact hidden payload even when
            // a richer attachment-specific reconstruction is unavailable.
            insertTextPill(payload, into: tv)
            return true
        }

        func addNativeRepresentations(
            for payload: String,
            to pasteboardItem: NSPasteboardItem,
            sourceConversationID: UUID?
        ) {
            if let restoredReference = exactArtifactReference(in: payload) {
                // A restored prompt token can name any local path. Re-resolve only its UUID through
                // the durable store, export that record's current source, and authenticate the
                // private representation. With no exact record the already-published "[Artifact]"
                // public string is the complete (and honest) drag payload.
                if let reference = ArtifactActions.durableExportReference(
                    for: restoredReference.artifactID,
                    temporaryRoot: parent.artifactExportRoot,
                    artifactStore: parent.artifactStore),
                   let data = reference.processSignedEncodedData {
                    pasteboardItem.setData(
                        data,
                        forType: ArtifactActions.referencePasteboardType)
                    pasteboardItem.setString(
                        reference.sourceURL.absoluteString,
                        forType: .fileURL)
                }
                return
            }
            if let reference = exactFileReference(in: payload),
               let sourceConversationID,
               let url = (parent.attachmentStore ?? ConversationStore.shared)
                .composerFileURL(
                    conversationID: sourceConversationID,
                    reference: reference) {
                pasteboardItem.setString(url.absoluteString, forType: .fileURL)
                return
            }
            if let path = exactImagePath(in: payload) {
                pasteboardItem.setString(
                    URL(fileURLWithPath: path).absoluteString,
                    forType: .fileURL)
            }
        }

        private func publicText(forDraggedAttachment payload: String) -> String {
            if exactArtifactReference(in: payload) != nil { return "[Artifact]" }
            if let reference = exactFileReference(in: payload) {
                return reference.isMailMessage ? "[Mail message]" : "[File attachment]"
            }
            if exactImagePath(in: payload) != nil { return "[Image]" }
            return payload
        }

        private func exactArtifactReference(in payload: String) -> ArtifactDragReference? {
            let matches = ArtifactDragReference.matches(in: payload)
            guard matches.count == 1,
                  matches[0].range == NSRange(location: 0, length: payload.utf16.count)
            else { return nil }
            return matches[0].reference
        }

        private func exactFileReference(in payload: String) -> ConversationFileReference? {
            ChatInput.exactFileReference(in: payload)
        }

        private func exactImagePath(in payload: String) -> String? {
            ChatInput.exactImagePath(in: payload)
        }

        /// Capture text and attachment payloads as separate ordered segments. Keeping their kind
        /// explicit prevents an ordinary text path from being mistaken for an attachment during
        /// cross-conversation cloning.
        func composerClipboardPayload(
            from tv: NSTextView
        ) -> ComposerClipboardPayload? {
            guard let storage = tv.textStorage else { return nil }
            let selection = tv.selectedRange()
            guard selection.length > 0,
                  selection.location >= 0,
                  NSMaxRange(selection) <= storage.length else { return nil }
            let selected = storage.attributedSubstring(from: selection)
            let selectedString = selected.string as NSString
            var segments: [ComposerClipboardPayload.Segment] = []

            func append(_ segment: ComposerClipboardPayload.Segment) {
                guard !segment.content.isEmpty else { return }
                if segment.kind == .text,
                   let last = segments.last,
                   last.kind == .text {
                    segments[segments.count - 1] = .init(
                        kind: .text,
                        content: last.content + segment.content)
                } else {
                    segments.append(segment)
                }
            }

            selected.enumerateAttributes(
                in: NSRange(location: 0, length: selected.length)
            ) { attributes, range, _ in
                guard attributes[.attachment] != nil,
                      let payload = attributes[ChatInput.payloadKey] as? String else {
                    append(.init(
                        kind: .text,
                        content: selectedString.substring(with: range)))
                    return
                }
                let kind: ComposerClipboardPayload.Segment.Kind
                if exactFileReference(in: payload) != nil {
                    kind = .file
                } else if exactArtifactReference(in: payload) != nil {
                    kind = .artifact
                } else if exactImagePath(in: payload) != nil {
                    kind = .image
                } else {
                    kind = .opaqueAttachment
                }
                append(.init(kind: kind, content: payload))
            }
            guard !segments.isEmpty else { return nil }
            return ComposerClipboardPayload(
                sourceConversationID: parent.conversationID,
                segments: segments)
        }

        /// Add the private representation after NSTextView has written its normal string/RTFD/image
        /// types. Public paste behavior in other apps remains native; Mechanician composers get the
        /// durable authored-order payload.
        @discardableResult
        func addComposerClipboardPayload(
            _ payload: ComposerClipboardPayload,
            processSignedData preparedData: Data? = nil,
            to pasteboard: NSPasteboard
        ) -> Bool {
            // Preflight before replacing any public flavor. If the bounded private descriptor
            // cannot be encoded, keep AppKit's native clipboard output intact.
            guard let data = preparedData ?? payload.processSignedEncodedData else { return false }
            if let composerClipboardWriteOverride {
                return composerClipboardWriteOverride(
                    pasteboard,
                    payload.publicText,
                    data)
            }
            guard pasteboard.setData(
                data,
                forType: ComposerClipboardPayload.pasteboardType) else {
                return false
            }
            // Replace AppKit's attachment-character string flavor with a readable projection, but
            // never expose hidden paths/tokens to apps that do not understand the private type.
            guard pasteboard.setString(payload.publicText, forType: .string),
                  pasteboard.data(
                    forType: ComposerClipboardPayload.pasteboardType) == data else {
                return false
            }
            return true
        }

        func composerClipboardPayload(
            from pasteboard: NSPasteboard
        ) -> ComposerClipboardPayload? {
            for item in (pasteboard.pasteboardItems ?? [])
                .prefix(ComposerClipboardPayload.maximumPasteboardItems) {
                guard let itemData = item.data(
                    forType: ComposerClipboardPayload.pasteboardType),
                      let payload = ComposerClipboardPayload.decodeProcessPrivate(
                        itemData) else { continue }
                return payload
            }
            return ComposerClipboardPayload.decodeProcessPrivate(
                pasteboard.data(forType: ComposerClipboardPayload.pasteboardType))
        }

        @discardableResult
        private func insertComposerClipboardPayload(
            _ payload: ComposerClipboardPayload,
            into tv: NSTextView
        ) -> Bool {
            guard !payload.segments.isEmpty,
                  let storage = tv.textStorage else { return false }
            let selection = tv.selectedRange()
            guard selection.location >= 0,
                  NSMaxRange(selection) <= storage.length,
                  tv.shouldChangeText(in: selection, replacementString: nil) else {
                return false
            }

            let segments: [ComposerClipboardPayload.Segment]
            if let sourceConversationID = payload.sourceConversationID,
               let destinationConversationID = parent.conversationID,
               sourceConversationID != destinationConversationID {
                segments = rehomedClipboardSegments(
                    payload.segments,
                    from: sourceConversationID,
                    to: destinationConversationID)
            } else if let sourceConversationID = payload.sourceConversationID,
                      sourceConversationID == parent.conversationID {
                segments = validatedOwnedClipboardSegments(
                    payload.segments,
                    conversationID: sourceConversationID)
            } else {
                segments = validatedOwnedClipboardSegments(
                    payload.segments,
                    conversationID: nil)
            }

            let replacement = NSMutableAttributedString()
            for segment in segments {
                replacement.append(attributedClipboardSegment(segment, in: tv))
            }
            storage.replaceCharacters(in: selection, with: replacement)
            tv.setSelectedRange(NSRange(
                location: selection.location + replacement.length,
                length: 0))
            tv.didChangeText()
            normalizePlainTextAttributes(tv)
            syncFromTextView()
            return true
        }

        private func rehomedClipboardSegments(
            _ segments: [ComposerClipboardPayload.Segment],
            from sourceConversationID: UUID,
            to destinationConversationID: UUID
        ) -> [ComposerClipboardPayload.Segment] {
            let store = parent.attachmentStore ?? ConversationStore.shared
            var budget = ConversationAttachmentImportBudget()
            return segments.map { segment in
                guard segment.kind == .image || segment.kind == .file else {
                    return segment
                }
                guard let maximumBytes = budget.beginAttachment() else {
                    return .init(
                        kind: .text,
                        content: budget.takeLimitMessage() ?? "")
                }

                switch segment.kind {
                case .image:
                    guard let path = exactImagePath(in: segment.content),
                          let clone = store.cloneComposerImagePath(
                            path,
                            from: sourceConversationID,
                            to: destinationConversationID,
                            maximumBytes: maximumBytes) else {
                        return .init(
                            kind: .text,
                            content: "[Pasted image unavailable. Attach it again]")
                    }
                    budget.recordCommittedBytes(clone.byteCount)
                    return .init(kind: .image, content: clone.path)

                case .file:
                    guard let reference = exactFileReference(in: segment.content),
                          let clone = store.cloneComposerFileReference(
                            reference,
                            from: sourceConversationID,
                            to: destinationConversationID,
                            maximumBytes: maximumBytes) else {
                        return .init(
                            kind: .text,
                            content: "[Attached file unavailable. Attach it again]")
                    }
                    budget.recordCommittedBytes(clone.byteCount)
                    return .init(kind: .file, content: clone.promptToken)

                case .text, .artifact, .opaqueAttachment:
                    return segment
                }
            }
        }

        private func validatedOwnedClipboardSegments(
            _ segments: [ComposerClipboardPayload.Segment],
            conversationID: UUID?
        ) -> [ComposerClipboardPayload.Segment] {
            let store = parent.attachmentStore ?? ConversationStore.shared
            return segments.map { segment in
                switch segment.kind {
                case .image:
                    guard let conversationID,
                          let path = exactImagePath(in: segment.content),
                          store.hasAvailableComposerImagePath(
                            path,
                            conversationID: conversationID) else {
                        return .init(
                            kind: .text,
                            content: "[Pasted image unavailable. Attach it again]")
                    }
                    return segment
                case .file:
                    guard let conversationID,
                          let reference = exactFileReference(in: segment.content),
                          store.composerFileURL(
                            conversationID: conversationID,
                            reference: reference) != nil else {
                        return .init(
                            kind: .text,
                            content: "[Attached file unavailable. Attach it again]")
                    }
                    return segment
                case .text, .artifact, .opaqueAttachment:
                    return segment
                }
            }
        }

        private func attributedClipboardSegment(
            _ segment: ComposerClipboardPayload.Segment,
            in tv: NSTextView
        ) -> NSAttributedString {
            let attachment: NSTextAttachment?
            switch segment.kind {
            case .text:
                return NSAttributedString(
                    string: segment.content,
                    attributes: plainTextAttributes)
            case .image:
                if let path = exactImagePath(in: segment.content),
                   let image = NSImage(contentsOfFile: path) {
                    let thumbnail = Self.thumbnail(image)
                    let imageAttachment = NSTextAttachment()
                    imageAttachment.image = thumbnail
                    imageAttachment.bounds = CGRect(
                        origin: .zero,
                        size: thumbnail.size)
                    attachment = imageAttachment
                } else {
                    attachment = nil
                }
            case .file:
                if let reference = exactFileReference(in: segment.content) {
                    let url = parent.conversationID.flatMap {
                        (parent.attachmentStore ?? ConversationStore.shared)
                            .composerFileURL(
                                conversationID: $0,
                                reference: reference)
                    }
                    attachment = fileAttachment(
                        for: reference,
                        url: url,
                        in: tv)
                } else {
                    attachment = nil
                }
            case .artifact:
                if let reference = exactArtifactReference(in: segment.content) {
                    attachment = artifactAttachment(for: reference)
                    parent.onArtifactReference?(reference)
                } else {
                    attachment = nil
                }
            case .opaqueAttachment:
                attachment = textPillAttachment(for: segment.content)
            }

            guard let attachment else {
                return NSAttributedString(
                    string: segment.content,
                    attributes: plainTextAttributes)
            }
            return attachmentPiece(
                attachment,
                payload: segment.content,
                additionalAttributes: [:])
        }

        /// Finder file drags/pastes call the same generalized drop path.
        @discardableResult
        func handleFileDrop(from pasteboard: NSPasteboard, into tv: NSTextView) -> Bool {
            handleDrop(from: pasteboard, into: tv)
        }

        private func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
            (pasteboard.readObjects(
                forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        }

        /// Handle a paste that should become an inline marker. Returns true if handled.
        private func attachFromPasteboard(
            _ pb: NSPasteboard,
            into tv: NSTextView
        ) -> Bool {
            // App-private mixed selections must win over AppKit's public bitmap/RTFD/string
            // representations. Those public types are intentionally still present for other apps,
            // but none carries destination ownership or complete authored ordering.
            if pb.availableType(
                from: [ComposerClipboardPayload.pasteboardType]) != nil {
                let visibleText = pb.string(forType: .string)
                guard let payload = composerClipboardPayload(from: pb) else {
                    guard let visibleText else { return false }
                    insertPlain(visibleText, into: tv)
                    return true
                }
                let store = parent.attachmentStore ?? ConversationStore.shared
                guard payload.isTrustedForCurrentProcess,
                      visibleText == payload.publicText,
                      let sourceConversationID = payload.sourceConversationID,
                      store.contains(sourceConversationID) else {
                    // A pasteboard UTI is a format hint, not proof of origin. Never let a forged or
                    // stale payload turn hidden artifact/text-pill content into a draft. Product
                    // copies always name an extant source conversation; everything else gets only
                    // the same readable public string another app would see.
                    guard let visibleText else {
                        return false
                    }
                    insertPlain(visibleText, into: tv)
                    return true
                }
                return insertComposerClipboardPayload(payload, into: tv)
            }

            // Genuine image BYTES on the clipboard (a screenshot, Preview/Photos "Copy", or a
            // browser "Copy Image") → temp PNG + inline thumbnail. Checked FIRST on purpose: those
            // sources also drop a file-url and/or HTML alongside the image, and the file-url /
            // rich-text branches below would otherwise win and paste a raw path. Gate on a raw bitmap
            // type — NOT NSImage(pasteboard:) alone — so a copied image FILE from Finder (file-url, no
            // decoded bytes) still falls through to the path branch. (⌘V reaches us at all only because
            // the text view sets importsGraphics=true; otherwise the paste action is validated off.)
            if pb.availableType(from: [.png, .tiff]) != nil, let image = NSImage(pasteboard: pb),
               let url = writePastedImage(image) {
                insertImageAttachment(image, path: url.path, into: tv)
                return true
            }

            // Files copied from Finder — paste ANY document. Image files → an inline thumbnail;
            // every other type (PDF, docx, code, …) → a compact "📎 name" chip. Both carry the real
            // path as the payload, so the agent can open the file.
            if handleDrop(from: pb, into: tv) { return true }

            // Any text: a large blob collapses into a pill; smaller text pastes plainly
            // (forced here so the rich text view can't pull in the source's fonts/colors).
            if let s = pb.string(forType: .string) {
                if s.count >= ChatInput.largeTextThreshold {
                    insertTextPill(s, into: tv)
                } else {
                    insertPlain(s, into: tv)
                }
                return true
            }
            return false
        }

        // MARK: Inserting

        private func insertPlain(_ s: String, into tv: NSTextView) {
            let range = tv.selectedRange()
            applyTypingAttributes(tv)
            if tv.shouldChangeText(in: range, replacementString: s) {
                tv.insertText(s, replacementRange: range)
                tv.didChangeText()
            }
            normalizePlainTextAttributes(tv)
            syncFromTextView()
        }

        private func insertImageAttachment(_ image: NSImage, path: String, into tv: NSTextView) {
            let thumb = Self.thumbnail(image)
            let att = NSTextAttachment()
            att.image = thumb
            att.bounds = CGRect(origin: .zero, size: thumb.size)
            insertAttachment(att, payload: path, into: tv)
        }

        /// A compact chip for a pasted file of ANY type — a "📎 name.ext" pill carrying the real path
        /// as its payload, so the agent can open it (images use a thumbnail instead).
        private func insertFileChip(_ url: URL, into tv: NSTextView) {
            let font = NSFont.systemFont(ofSize: parent.fontSize)
            let img = Self.pillImage("📎 \(url.lastPathComponent)", font: font)
            let att = NSTextAttachment()
            att.image = img
            att.bounds = CGRect(x: 0, y: font.descender, width: img.size.width, height: img.size.height)
            insertAttachment(att, payload: url.path, into: tv)
        }

        private func insertFileReference(
            _ reference: ConversationFileReference,
            url: URL,
            into tv: NSTextView
        ) {
            insertAttachment(
                fileAttachment(for: reference, url: url, in: tv),
                payload: reference.promptToken,
                into: tv)
        }

        private func fileAttachment(
            for reference: ConversationFileReference,
            url: URL?,
            in tv: NSTextView?
        ) -> NSTextAttachment {
            let attachment = NSTextAttachment()
            configureFileAttachment(
                attachment,
                reference: reference,
                url: url,
                in: tv)
            return attachment
        }

        private func configureFileAttachment(
            _ attachment: NSTextAttachment,
            reference: ConversationFileReference,
            url: URL?,
            in tv: NSTextView?
        ) {
            let resolvedURL = url ?? URL(fileURLWithPath: reference.displayName)
            let fontSize = parent.fontSize
            let font = NSFont.systemFont(ofSize: fontSize)
            let appearance = tv?.effectiveAppearance ?? NSApp.effectiveAppearance
            let fallback = ConversationFilePreview.composerCard(
                reference: reference,
                url: resolvedURL,
                preview: nil,
                fontSize: fontSize,
                appearance: appearance)
            let announcement = ChatInput.attachmentAccessibilityLabel(for: reference)
            fallback.accessibilityDescription = announcement
            attachment.image = fallback
            attachment.bounds = CGRect(
                x: 0,
                y: font.descender,
                width: fallback.size.width,
                height: fallback.size.height)
            if let url, let tv, !reference.isMailMessage {
                let appearanceName = appearance.bestMatch(from: [.aqua, .darkAqua])
                Task { @MainActor [weak attachment, weak tv] in
                    guard let preview = await ConversationFilePreview.thumbnail(
                        for: url,
                        size: ConversationFilePreview.composerPreviewSize,
                        scale: tv?.window?.backingScaleFactor
                            ?? NSScreen.main?.backingScaleFactor
                            ?? 2),
                          let attachment,
                          let tv,
                          tv.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
                            == appearanceName else { return }
                    let card = ConversationFilePreview.composerCard(
                        reference: reference,
                        url: url,
                        preview: preview,
                        fontSize: fontSize,
                        appearance: tv.effectiveAppearance)
                    // The thumbnail render replaces the image built above, so it must carry the
                    // announcement forward or the attachment silently loses its description.
                    card.accessibilityDescription = announcement
                    attachment.image = card
                    attachment.bounds = CGRect(
                        x: 0,
                        y: font.descender,
                        width: card.size.width,
                        height: card.size.height)
                    tv.needsDisplay = true
                }
            }
        }

        /// NSTextAttachment images are static bitmaps. Re-render generic file cards when their
        /// window's effective appearance changes instead of leaving a Light card frozen in Dark.
        func refreshFileAttachmentAppearance(in tv: NSTextView) {
            guard let storage = tv.textStorage, storage.length > 0 else { return }
            storage.enumerateAttributes(
                in: NSRange(location: 0, length: storage.length)
            ) { attributes, _, _ in
                guard let attachment = attributes[.attachment] as? NSTextAttachment,
                      let payload = attributes[ChatInput.payloadKey] as? String,
                      let reference = exactFileReference(in: payload) else { return }
                let url = parent.conversationID.flatMap {
                    (parent.attachmentStore ?? ConversationStore.shared).composerFileURL(
                        conversationID: $0,
                        reference: reference)
                }
                configureFileAttachment(
                    attachment,
                    reference: reference,
                    url: url,
                    in: tv)
            }
            tv.needsDisplay = true
        }

        private func insertArtifactReference(_ reference: ArtifactDragReference, into tv: NSTextView) {
            let attachment = artifactAttachment(for: reference)
            if insertAttachment(attachment, payload: reference.promptToken, into: tv) {
                parent.onArtifactReference?(reference)
            }
        }

        private func artifactAttachment(for reference: ArtifactDragReference) -> NSTextAttachment {
            let font = NSFont.systemFont(ofSize: parent.fontSize)
            let title = String(reference.title.prefix(80))
            let image = Self.pillImage("◈ \(title) · \(reference.type.uppercased())", font: font)
            let attachment = NSTextAttachment()
            attachment.image = image
            attachment.bounds = CGRect(
                x: 0,
                y: font.descender,
                width: image.size.width,
                height: image.size.height)
            return attachment
        }

        private func insertTextPill(_ fullText: String, into tv: NSTextView) {
            insertAttachment(
                textPillAttachment(for: fullText),
                payload: fullText,
                into: tv)
        }

        private func textPillAttachment(for fullText: String) -> NSTextAttachment {
            let label = "📄 Pasted text · \(Self.charCountLabel(fullText.count))"
            let att = NSTextAttachment()
            let font = NSFont.systemFont(ofSize: parent.fontSize)
            let img = Self.pillImage(label, font: font)
            att.image = img
            att.bounds = CGRect(x: 0, y: font.descender, width: img.size.width, height: img.size.height)
            return att
        }

        /// Insert an attachment carrying `payload` (expanded on send), then a trailing
        /// space, and reset typing attributes so following text is plain.
        @discardableResult
        private func insertAttachment(
            _ att: NSTextAttachment,
            payload: String,
            additionalAttributes: [NSAttributedString.Key: Any] = [:],
            into tv: NSTextView
        ) -> Bool {
            let piece = attachmentPiece(
                att,
                payload: payload,
                additionalAttributes: additionalAttributes)
            piece.append(NSAttributedString(string: " ", attributes: [
                .font: NSFont.systemFont(ofSize: parent.fontSize),
                .foregroundColor: NSColor.labelColor,
            ]))
            let range = tv.selectedRange()
            guard tv.shouldChangeText(in: range, replacementString: nil) else { return false }
            tv.textStorage?.replaceCharacters(in: range, with: piece)
            tv.didChangeText()
            tv.setSelectedRange(NSRange(location: range.location + piece.length, length: 0))
            normalizePlainTextAttributes(tv)
            syncFromTextView()
            return true
        }

        private func attachmentPiece(
            _ attachment: NSTextAttachment,
            payload: String,
            additionalAttributes: [NSAttributedString.Key: Any]
        ) -> NSMutableAttributedString {
            let piece = NSMutableAttributedString(attachment: attachment)
            // An attachment renders as a bitmap pill, so without this it reaches VoiceOver as an
            // unspoken object-replacement character. Every attachment kind funnels through here.
            attachment.image?.accessibilityDescription =
                ChatInput.attachmentAccessibilityLabel(forPayload: payload)
            // Carry text color + font on the attachment glyph itself, so text typed BEFORE it (cursor
            // at that position) inherits labelColor instead of defaulting to black.
            var attributes: [NSAttributedString.Key: Any] = [
                ChatInput.payloadKey: payload,
                .foregroundColor: NSColor.labelColor,
                .font: NSFont.systemFont(ofSize: parent.fontSize),
            ]
            attributes.merge(additionalAttributes) { _, replacement in replacement }
            piece.addAttributes(
                attributes,
                range: NSRange(location: 0, length: piece.length))
            return piece
        }

        /// Rebuild the attributed composer from its durable flattened prompt. Images retain their
        /// paths; artifacts and generic files use compact tagged JSON at the exact insertion point,
        /// so navigation/Edit & Resend restores every visual attachment without persisting RTF.
        func restoreSerializedContent(_ serialized: String, into tv: NSTextView) {
            enum Marker {
                case image(path: String, image: NSImage)
                case artifact(ArtifactDragReference)
                case file(ConversationFileReference, URL?)
            }
            struct PositionedMarker {
                let range: NSRange
                let marker: Marker
            }

            let result = NSMutableAttributedString()
            let ns = serialized as NSString
            var markers = ImagePathDetector.matches(in: serialized).compactMap { match -> PositionedMarker? in
                guard let image = NSImage(contentsOfFile: match.path) else { return nil }
                return PositionedMarker(
                    range: match.range,
                    marker: .image(path: match.path, image: image))
            }
            markers.append(contentsOf: ArtifactDragReference.matches(in: serialized).map {
                PositionedMarker(range: $0.range, marker: .artifact($0.reference))
            })
            markers.append(contentsOf: ConversationFileReference.matches(in: serialized).map { match in
                let url: URL?
                if let conversationID = parent.conversationID {
                    url = (parent.attachmentStore ?? ConversationStore.shared)
                        .composerFileURL(
                        conversationID: conversationID,
                        reference: match.reference)
                } else {
                    url = nil
                }
                return PositionedMarker(
                    range: match.range,
                    marker: .file(match.reference, url))
            })
            markers.sort {
                if $0.range.location != $1.range.location {
                    return $0.range.location < $1.range.location
                }
                return $0.range.length > $1.range.length
            }
            var cursor = 0

            func appendText(_ range: NSRange) {
                guard range.length > 0 else { return }
                result.append(NSAttributedString(
                    string: ns.substring(with: range),
                    attributes: plainTextAttributes))
            }

            for positioned in markers where positioned.range.location >= cursor {
                appendText(NSRange(
                    location: cursor,
                    length: positioned.range.location - cursor))
                let attachment: NSTextAttachment
                let payload: String
                switch positioned.marker {
                case .image(let path, let image):
                    let thumb = Self.thumbnail(image)
                    attachment = NSTextAttachment()
                    attachment.image = thumb
                    attachment.bounds = CGRect(origin: .zero, size: thumb.size)
                    payload = path
                case .artifact(let reference):
                    attachment = artifactAttachment(for: reference)
                    payload = reference.promptToken
                case .file(let reference, let url):
                    attachment = fileAttachment(for: reference, url: url, in: tv)
                    payload = reference.promptToken
                }
                // Share the insertion path's assembly so a restored draft carries the same payload,
                // colour, font, and spoken description as a freshly attached file.
                result.append(attachmentPiece(
                    attachment,
                    payload: payload,
                    additionalAttributes: [:]))
                cursor = NSMaxRange(positioned.range)
            }
            appendText(NSRange(location: cursor, length: ns.length - cursor))

            // If no valid attachment marker was reconstructed, preserve the source literally.
            if result.length == 0, !serialized.isEmpty {
                result.append(NSAttributedString(string: serialized, attributes: plainTextAttributes))
            }
            tv.textStorage?.setAttributedString(result)
            lastSerialized = serialized
            normalizePlainTextAttributes(tv)
        }

        private var plainTextAttributes: [NSAttributedString.Key: Any] {
            [
                .font: NSFont.systemFont(ofSize: parent.fontSize),
                .foregroundColor: NSColor.labelColor,
            ]
        }

        // MARK: Serialization (attributed → plain prompt with payloads expanded)

        /// The prompt string: normal characters verbatim, each attachment replaced by its
        /// hidden payload (image path or the full pasted text).
        func serialize(_ tv: NSTextView) -> String {
            guard let storage = tv.textStorage else { return tv.string }
            var out = ""
            let ns = storage.string as NSString
            storage.enumerateAttributes(in: NSRange(location: 0, length: storage.length)) { attrs, range, _ in
                // Expand the payload ONLY for a real attachment glyph. Text typed with the cursor parked
                // just BEFORE an attachment inherits the payloadKey attribute (NSTextView copies the
                // adjacent char's typing attributes); without the `.attachment` guard that typed text
                // would be replaced by the path (words lost) and the path emitted twice.
                if attrs[.attachment] != nil, let payload = attrs[ChatInput.payloadKey] as? String {
                    out += payload
                } else {
                    out += ns.substring(with: range)
                }
            }
            return out
        }

        private func syncFromTextView() {
            guard let tv = textView else { return }
            let serialized = serialize(tv)
            lastSerialized = serialized
            parent.text = serialized
            recalcHeight()
        }

        // MARK: Rendering helpers

        private static func thumbnail(_ image: NSImage, maxW: CGFloat = 150, maxH: CGFloat = 96) -> NSImage {
            let s = image.size
            guard s.width > 0, s.height > 0 else { return image }
            let scale = min(maxW / s.width, maxH / s.height, 1)
            let newSize = NSSize(width: round(s.width * scale), height: round(s.height * scale))
            let t = NSImage(size: newSize)
            t.lockFocus()
            image.draw(in: NSRect(origin: .zero, size: newSize),
                       from: .zero, operation: .copy, fraction: 1)
            t.unlockFocus()
            return t
        }

        private static func charCountLabel(_ n: Int) -> String {
            if n >= 1000 { return String(format: "%.1fk chars", Double(n) / 1000) }
            return "\(n) chars"
        }

        /// A rounded accent pill with a label, rendered to an image so it can live inside
        /// an NSTextAttachment.
        private static func pillImage(_ label: String, font: NSFont) -> NSImage {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font, .foregroundColor: NSColor.white,
            ]
            let text = label as NSString
            let textSize = text.size(withAttributes: attrs)
            let padH: CGFloat = 9, padV: CGFloat = 4
            let size = NSSize(width: ceil(textSize.width) + padH * 2,
                              height: ceil(textSize.height) + padV * 2)
            let img = NSImage(size: size)
            img.lockFocus()
            let rect = NSRect(origin: .zero, size: size)
            let path = NSBezierPath(roundedRect: rect, xRadius: size.height / 2, yRadius: size.height / 2)
            // Full-opacity saturated selection color so the white label stays legible in light
            // mode and for pale user accents (was controlAccentColor at 0.9 alpha).
            NSColor.selectedContentBackgroundColor.setFill()
            path.fill()
            text.draw(at: NSPoint(x: padH, y: padV), withAttributes: attrs)
            img.unlockFocus()
            return img
        }

        private func writePastedImage(_ image: NSImage) -> URL? {
            guard let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else { return nil }
            if let conversationID = parent.conversationID {
                return (parent.attachmentStore ?? ConversationStore.shared)
                    .persistComposerImage(
                        png,
                        conversationID: conversationID,
                        width: Int(image.size.width.rounded()),
                        height: Int(image.size.height.rounded()))
            }
            let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("mechanician-paste", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("pasted-\(UUID().uuidString).png")
            do { try png.write(to: url); return url } catch { return nil }
        }

        // MARK: Editing

        func nativeTextDidChange(_ tv: NSTextView) {
            guard tv === textView else { return }
            normalizePlainTextAttributes(tv)
            syncFromTextView()
            updateCompletion()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            applyTypingAttributes(tv)
        }

        func textDidEndEditing(_ notification: Notification) {
            completion.hide()
        }

        func textView(_ textView: NSTextView, doCommandBy sel: Selector) -> Bool {
            // ⌥Return arrives here as insertNewlineIgnoringFieldEditor: — interrupt the running
            // turn with this prompt. This selector is produced ONLY by ⌥Return (plain and
            // ⇧Return come through insertNewline:), so we don't re-check the modifier — the
            // current NSEvent.modifierFlags is unreliable by the time this runs. Owning it here
            // and returning true is what actually suppresses the newline; a local key monitor
            // returning nil does not.
            if sel == #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)) {
                if let interject = parent.onInterject {
                    completion.hide()
                    interject()
                } else {
                    textView.insertNewlineIgnoringFieldEditor(nil)
                    recalcHeight()
                }
                return true
            }

            // While the slash-command popover is open it owns nav / accept / dismiss keys.
            if completion.isVisible {
                switch sel {
                case #selector(NSResponder.moveUp(_:)):
                    completion.moveSelection(-1); return true
                case #selector(NSResponder.moveDown(_:)):
                    completion.moveSelection(1); return true
                case #selector(NSResponder.insertTab(_:)), #selector(NSResponder.insertNewline(_:)):
                    acceptCompletion(); return true
                case #selector(NSResponder.cancelOperation(_:)):
                    completion.hide(); return true
                default:
                    break
                }
            }

            // ⌥Return is handled by the key monitor above (it routes to a different
            // selector). Here: ⇧Return inserts a newline, plain Return sends.
            if sel == #selector(NSResponder.insertNewline(_:)) {
                if NSEvent.modifierFlags.contains(.shift) {
                    textView.insertNewlineIgnoringFieldEditor(nil)
                    recalcHeight()
                } else {
                    completion.hide()
                    parent.onSend()
                }
                return true
            }
            return false
        }

        // MARK: Slash-command autocomplete

        /// Refresh the popover from the composer's current text. A leading "/word" offers slash
        /// commands; an "@…" token at the cursor offers directory/file paths (with ~ for home).
        private func updateCompletion() {
            guard let tv = textView, tv.window?.firstResponder === tv else {
                completion.hide(); completionMode = .none; return
            }
            let s = tv.string
            // 1) Slash command — the whole prompt is a single "/word" typed at the start.
            if s.first == "/", !s.dropFirst().contains(where: { $0.isWhitespace }) {
                let prefix = s.dropFirst().lowercased()
                // The same filter the Skills panel uses, so the two surfaces agree — a panel saying
                // 29 beside a popover offering 45 reads as a bug. This hides them from SUGGESTIONS
                // only: a command typed in full is still sent, which is what makes the panel's
                // "they still work if you type them" promise true.
                let matches = parent.slashCommands.filter { command in
                    guard command.prefix == "/" else { return false }
                    guard prefix.isEmpty || command.name.lowercased().hasPrefix(prefix) else { return false }
                    return !SkillVisibility.isTerminalOnly(command.name)
                }
                if matches.isEmpty { completion.hide(); completionMode = .none }
                else { completionMode = .slash; completion.show(matches, anchor: tv, prefix: "/") }
                return
            }
            // 2) @-path — an "@token" ending at the cursor (mid-prompt is fine).
            if let (range, frag) = pathToken(tv) {
                let (dirPart, items) = pathCandidates(fragment: frag)
                if items.isEmpty { completion.hide(); completionMode = .none }
                else {
                    completionMode = .path; pathTokenRange = range; pathDirPart = dirPart
                    completion.show(items, anchor: tv, prefix: "")
                }
                return
            }
            completion.hide(); completionMode = .none
        }

        /// Accept the highlighted item: a slash command (whole-prompt "/name ") or a path
        /// (reassemble "@dir/leaf" into the @token's range).
        private func acceptCompletion() {
            guard let tv = textView, let sel = completion.selected else { return }
            completion.hide()
            let replacement: String
            let range: NSRange
            switch completionMode {
            case .slash:
                replacement = "/\(sel.name) "
                range = NSRange(location: 0, length: (tv.string as NSString).length)
            case .path:
                guard let r = pathTokenRange else { return }
                replacement = "@" + pathDirPart + sel.name   // sel.name is the leaf (+ "/" for dirs)
                range = r
            case .none:
                return
            }
            if tv.shouldChangeText(in: range, replacementString: replacement) {
                tv.insertText(replacement, replacementRange: range)
                tv.didChangeText()
            }
            applyTypingAttributes(tv)
            syncFromTextView()
            // Just completed a directory → re-open so the user can keep drilling in.
            if completionMode == .path, replacement.hasSuffix("/") {
                DispatchQueue.main.async { self.updateCompletion() }
            }
        }

        /// The "@token" ending at the cursor, if any: its full range (including the @) and the
        /// path fragment after the @. The @ must start a word (preceded by whitespace or start)
        /// so email addresses like "a@b" don't trigger.
        private func pathToken(_ tv: NSTextView) -> (NSRange, String)? {
            let ns = tv.string as NSString
            let cursor = tv.selectedRange().location
            guard cursor >= 1, cursor <= ns.length else { return nil }
            let ws = CharacterSet.whitespacesAndNewlines
            var i = cursor
            while i > 0 {
                guard let c = Unicode.Scalar(ns.character(at: i - 1)) else { return nil }
                if c == "@" {
                    let precededOK = (i - 1 == 0) || (Unicode.Scalar(ns.character(at: i - 2)).map(ws.contains) ?? false)
                    guard precededOK else { return nil }
                    let range = NSRange(location: i - 1, length: cursor - (i - 1))
                    let frag = ns.substring(with: NSRange(location: i, length: cursor - i))
                    return (range, frag)
                }
                if ws.contains(c) { return nil } // hit whitespace before an @ — no token
                i -= 1
            }
            return nil
        }

        /// Directory listing candidates for an @-path fragment. Returns the directory portion of
        /// the fragment (to reassemble on accept) and the matching entries as items whose `name`
        /// is the leaf (folders get a trailing "/").
        private func pathCandidates(fragment frag: String) -> (String, [SlashCommandInfo]) {
            // Split into "dir part" (up to and including the last /) and the stub to match.
            var dirPart: String
            var stub: String
            if frag == "~" { dirPart = "~/"; stub = "" }            // "@~" means home
            else if let r = frag.range(of: "/", options: .backwards) {
                dirPart = String(frag[..<frag.index(after: r.lowerBound)])
                stub = String(frag[frag.index(after: r.lowerBound)...])
            } else { dirPart = ""; stub = frag }

            // Resolve the dir part to an absolute directory to list.
            let base: String
            if dirPart.hasPrefix("/") { base = dirPart }
            else if dirPart.hasPrefix("~") { base = (dirPart as NSString).expandingTildeInPath }
            else { base = (parent.cwd.isEmpty ? NSHomeDirectory() : parent.cwd) + "/" + dirPart }

            let fm = FileManager.default
            let entries = (try? fm.contentsOfDirectory(atPath: base)) ?? []
            let lowerStub = stub.lowercased()
            let items = entries
                .filter { lowerStub.isEmpty || $0.lowercased().hasPrefix(lowerStub) }
                .filter { !$0.hasPrefix(".") || stub.hasPrefix(".") } // hide dotfiles unless asked for
                .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
                .prefix(60)
                .map { name -> SlashCommandInfo in
                    var isDir: ObjCBool = false
                    fm.fileExists(atPath: base + "/" + name, isDirectory: &isDir)
                    return SlashCommandInfo(name: name + (isDir.boolValue ? "/" : ""),
                                            description: "", argumentHint: "")
                }
            return (dirPart, Array(items))
        }

        func recalcHeight(invalidateLayout: Bool = false) {
            guard let tv = textView, let lm = tv.layoutManager, let tc = tv.textContainer
            else { return }
            if invalidateLayout {
                let fullRange = NSRange(location: 0, length: tv.textStorage?.length ?? 0)
                lm.invalidateLayout(forCharacterRange: fullRange, actualCharacterRange: nil)
            }
            lm.ensureLayout(for: tc)
            let used = lm.usedRect(for: tc).height + tv.textContainerInset.height * 2
            let oneLine = ChatInput.minimumSingleLineHeight(fontSize: parent.fontSize)
            let clamped = min(max(used, oneLine), ChatInput.maxHeight)
            let comparisonHeight = pendingHeight ?? parent.height
            guard abs(comparisonHeight - clamped) > 0.5 else { return }

            pendingHeight = clamped
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      let pendingHeight = self.pendingHeight,
                      abs(pendingHeight - clamped) <= 0.5
                else { return }
                self.pendingHeight = nil
                guard abs(self.parent.height - clamped) > 0.5 else { return }
                self.parent.height = clamped
            }
        }
    }
}
