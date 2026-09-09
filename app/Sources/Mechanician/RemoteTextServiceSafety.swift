import AppKit

/// Mitigates the macOS 27 ViewBridge crash tracked by Apple as FB23642313.
///
/// On affected builds, AppKit can leave SafariPlatformSupport's remote text-completion view
/// attached to an editable text view, then abort when any other window is ordered onscreen. The
/// exception is outside Swift's error model, so it cannot be caught at the presentation call.
/// Retiring the active editor before the order operation removes the trigger; a short quiet period
/// lets the out-of-process view service observe that retirement before AppKit posts the next
/// window-order notification.
@MainActor
enum RemoteTextServiceSafety {
    static let affectedMajorVersion = 27
    static let retirementDelayNanoseconds: UInt64 = 150_000_000
    static let dismissalPollNanoseconds: UInt64 = 10_000_000
    static let dismissalPollLimit = 100

    static var isAffectedSystem: Bool {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion == affectedMajorVersion
    }

    static func presentationDelayNanoseconds(forMajorVersion majorVersion: Int) -> UInt64 {
        majorVersion == affectedMajorVersion ? retirementDelayNanoseconds : 0
    }

    /// These are precisely the services that can create the out-of-process completion view. This
    /// does not alter the editor's text or undo history.
    static func disableRemoteCompletion(on editor: NSTextView) {
        editor.isAutomaticTextCompletionEnabled = false
        editor.inlinePredictionType = .no
        editor.writingToolsBehavior = .none
    }

    /// Ends an affected active editing session before another window is ordered.
    ///
    /// `force` is a regression-test seam so CI running an older macOS can exercise the real AppKit
    /// transition. Production always uses the OS gate.
    @discardableResult
    static func retireActiveEditor(in window: NSWindow?, force: Bool = false) -> Bool {
        guard force || isAffectedSystem,
              let window else { return false }
        let activeEditor = window.firstResponder as? NSTextView
        // A shared field editor can retain SafariPlatformSupport's remote completion view after
        // AppKit has already moved first responder elsewhere. Configure that exact editor too;
        // checking only `firstResponder` left the remote service alive in the crash window.
        let sharedEditor = window.fieldEditor(false, for: nil) as? NSTextView
        guard activeEditor != nil || sharedEditor != nil else { return false }
        if let activeEditor {
            disableRemoteCompletion(on: activeEditor)
        }
        if let sharedEditor, sharedEditor !== activeEditor {
            disableRemoteCompletion(on: sharedEditor)
        }
        // Resign the editor so AppKit retires any completion UI. Ordering the next window is
        // deliberately deferred by the caller.
        return window.makeFirstResponder(nil)
    }

    /// Wait for the exact native popover window to leave the screen before publishing state that
    /// can replace or reflow its SwiftUI anchor. A timer alone is not dismissal evidence: on a busy
    /// main thread the old popover can still be visible when the timer fires. The operation receives
    /// `false` after one second or when no exact window was captured, and callers must fail closed.
    @discardableResult
    static func deferUntilWindowIsNoLongerVisible(
        from window: NSWindow?,
        majorVersion: Int = ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
        operation: @escaping @MainActor (_ didOrderOff: Bool) -> Void
    ) -> Task<Void, Never> {
        _ = retireActiveEditor(in: window, force: majorVersion == affectedMajorVersion)
        return Task { @MainActor in
            // Give SwiftUI one explicit AppKit pass to consume the caller's `isPresented = false`.
            await withCheckedContinuation {
                (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.main.async { continuation.resume() }
            }
            guard !Task.isCancelled else { return }
            guard let window else {
                operation(false)
                return
            }

            for _ in 0..<dismissalPollLimit where window.isVisible {
                do {
                    try await Task.sleep(nanoseconds: dismissalPollNanoseconds)
                } catch {
                    return
                }
            }
            guard !Task.isCancelled else { return }
            guard !window.isVisible else {
                operation(false)
                return
            }

            // The native window is now offscreen. On macOS 27, retain the existing short quiet
            // period so the out-of-process text service can observe the field-editor retirement.
            let delay = presentationDelayNanoseconds(forMajorVersion: majorVersion)
            if delay > 0 {
                do {
                    try await Task.sleep(nanoseconds: delay)
                } catch {
                    return
                }
            }
            guard !Task.isCancelled else { return }
            operation(true)
        }
    }

    /// Run a window-order-sensitive mutation only after AppKit has had a chance to retire the
    /// current editor and its out-of-process completion view.
    ///
    /// Even on unaffected systems the operation starts on a later main-actor pass. Callers use
    /// this boundary when the mutation can dismiss, present, or re-anchor an `NSPopover`; doing it
    /// inline with provider-driven SwiftUI reflow is unsafe independently of the macOS 27 delay.
    @discardableResult
    static func deferWindowOrderSensitiveMutation(
        from window: NSWindow?,
        majorVersion: Int = ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
        operation: @escaping @MainActor () -> Void
    ) -> Task<Void, Never> {
        // `majorVersion` is also the test seam for the real AppKit retirement path. In production
        // it is the current OS major, so forcing here does not widen the mitigation to unaffected
        // systems.
        _ = retireActiveEditor(in: window, force: majorVersion == affectedMajorVersion)
        let delay = presentationDelayNanoseconds(forMajorVersion: majorVersion)
        return Task { @MainActor in
            // Make the caller's dismissal observable before any state change that can reflow its
            // anchor, even when no OS-specific quiet period is required. `Task.yield()` alone is
            // not an AppKit run-loop boundary; enqueue explicitly on the main dispatch queue.
            await withCheckedContinuation {
                (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.main.async { continuation.resume() }
            }
            guard !Task.isCancelled else { return }
            if delay > 0 {
                do {
                    try await Task.sleep(nanoseconds: delay)
                } catch {
                    return
                }
            }
            guard !Task.isCancelled else { return }
            operation()
        }
    }
}
