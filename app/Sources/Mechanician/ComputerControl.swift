import AppKit
import CoreGraphics
import ApplicationServices
import ScreenCaptureKit

/// Computer use runs from the APP process (not a child helper) so a single
/// Accessibility / Screen Recording grant to Mechanician covers it — macOS applies
/// those permissions to the calling process, and a spawned CLI helper isn't reliably
/// covered by the app's grant. agentd requests these actions over the bridge.
enum ComputerControl {
    struct Result: Sendable {
        var ok: Bool
        var error: String?
        var image: String?   // base64 PNG (screenshot)
        var w: Int?
        var h: Int?
        var text: String?    // frontmost app name / clipboard contents
    }

    /// Serial queue for the synchronous AX / CGEvent / `open -a` work. The caller runs `perform`
    /// here instead of on the main actor: a `read_ui` walk (hundreds of cross-process AX messages)
    /// or an `activate_app` `waitUntilExit()` against a hung target would otherwise freeze the whole
    /// app AND stall agentd's event reader (which delivers events via `DispatchQueue.main.sync`).
    /// Serial preserves ordering (e.g. move-before-click).
    static let workQueue = DispatchQueue(label: "ai.mechanician.computer-control", qos: .userInitiated)

    static func perform(action: String, args: [String: Any]) -> Result {
        func d(_ k: String) -> Double { (args[k] as? NSNumber)?.doubleValue ?? (args[k] as? Double) ?? 0 }
        func pt(_ kx: String, _ ky: String) -> CGPoint { CGPoint(x: d(kx), y: d(ky)) }
        switch action {
        // "screenshot" is handled asynchronously by the caller (ScreenCaptureKit is async); it never
        // reaches `perform`. Guard defensively so a stray sync call is obvious rather than silent.
        case "screenshot":  return Result(ok: false, error: "internal: screenshot must be captured asynchronously")
        case "click":       clickAt(pt("x", "y"), button: .left, clicks: 1)
        case "rightclick":  clickAt(pt("x", "y"), button: .right, clicks: 1)
        case "doubleclick": clickAt(pt("x", "y"), button: .left, clicks: 2)
        case "move":        post(.mouseMoved, pt("x", "y"))
        case "drag":
            let a = pt("x1", "y1"), b = pt("x2", "y2")
            post(.mouseMoved, a); post(.leftMouseDown, a); post(.leftMouseDragged, b); post(.leftMouseUp, b)
        case "scroll":
            if let e = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2,
                               wheel1: Int32(d("dy")), wheel2: Int32(d("dx")), wheel3: 0) {
                e.post(tap: .cghidEventTap)
            }
        case "type":        typeText(args["text"] as? String ?? "")
        case "key":         return pressKey(args["combo"] as? String ?? "")
        case "activate_app":
            let name = args["name"] as? String ?? ""
            return activateApp(name)
                ? Result(ok: true)
                : Result(ok: false, error: "couldn't launch or activate \(name)")
        case "frontmost_app":
            return Result(ok: true, text: NSWorkspace.shared.frontmostApplication?.localizedName ?? "unknown")
        case "clipboard_get":
            return Result(ok: true, text: NSPasteboard.general.string(forType: .string) ?? "")
        case "clipboard_set":
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(args["text"] as? String ?? "", forType: .string)
            return Result(ok: true)
        case "read_ui":
            return Result(ok: true, text: readUITree())
        default:            return Result(ok: false, error: "unknown action: \(action)")
        }
        return Result(ok: true)
    }

    /// Bring an app to the front by name, launching it if it isn't running. Reliable
    /// focus is the key to typing into the right app.
    private static func activateApp(_ name: String) -> Bool {
        let running = NSWorkspace.shared.runningApplications
        if let app = running.first(where: { $0.localizedName?.caseInsensitiveCompare(name) == .orderedSame }) {
            return app.activate(options: [.activateAllWindows])
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-a", name]
        do { try p.run(); p.waitUntilExit(); return p.terminationStatus == 0 } catch { return false }
    }

    // MARK: Mouse

    private static func post(_ type: CGEventType, _ p: CGPoint, _ button: CGMouseButton = .left, clicks: Int64 = 1) {
        guard let e = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: button)
        else { return }
        e.setIntegerValueField(.mouseEventClickState, value: clicks)
        e.post(tap: .cghidEventTap)
    }

    private static func clickAt(_ p: CGPoint, button: CGMouseButton, clicks: Int64) {
        let down: CGEventType = button == .right ? .rightMouseDown : .leftMouseDown
        let up: CGEventType = button == .right ? .rightMouseUp : .leftMouseUp
        post(.mouseMoved, p)
        post(down, p, button, clicks: clicks)
        post(up, p, button, clicks: clicks)
    }

    // MARK: Keyboard

    private static func typeText(_ text: String) {
        for ch in text {
            if let (kc, shift) = keyCodeForChar(ch) {
                postKey(kc, shift: shift)   // real key-code event (accepted by Spotlight etc.)
            } else {
                typeUnicode(ch)             // fallback for anything unmapped (emoji, accents)
            }
        }
    }

    private static func postKey(_ kc: CGKeyCode, shift: Bool) {
        let flags: CGEventFlags = shift ? [.maskShift] : []
        for keyDown in [true, false] {
            guard let e = CGEvent(keyboardEventSource: nil, virtualKey: kc, keyDown: keyDown) else { continue }
            e.flags = flags
            e.post(tap: .cghidEventTap)
        }
    }

    private static func typeUnicode(_ ch: Character) {
        for scalar in String(ch).unicodeScalars where scalar.value <= 0xFFFF {
            var u = UniChar(scalar.value)
            for keyDown in [true, false] {
                guard let e = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: keyDown) else { continue }
                e.keyboardSetUnicodeString(stringLength: 1, unicodeString: &u)
                e.post(tap: .cghidEventTap)
            }
        }
    }

    /// Map a character to a US-layout key code + whether Shift is needed.
    private static func keyCodeForChar(_ ch: Character) -> (CGKeyCode, Bool)? {
        if let kc = keyCodes[ch.lowercased()] { return (kc, ch.isUppercase) }
        switch ch {
        case " ":  return (49, false)
        case "\n": return (36, false)
        case "\t": return (48, false)
        case "-":  return (27, false); case "_": return (27, true)
        case "=":  return (24, false); case "+": return (24, true)
        case ".":  return (47, false); case ">": return (47, true)
        case ",":  return (43, false); case "<": return (43, true)
        case "/":  return (44, false); case "?": return (44, true)
        case ";":  return (41, false); case ":": return (41, true)
        case "'":  return (39, false); case "\"": return (39, true)
        case "[":  return (33, false); case "{": return (33, true)
        case "]":  return (30, false); case "}": return (30, true)
        case "\\": return (42, false); case "|": return (42, true)
        case "`":  return (50, false); case "~": return (50, true)
        case "!":  return (18, true);  case "@": return (19, true)
        case "#":  return (20, true);  case "$": return (21, true)
        case "%":  return (23, true);  case "^": return (22, true)
        case "&":  return (26, true);  case "*": return (28, true)
        case "(":  return (25, true);  case ")": return (29, true)
        default:   return nil
        }
    }

    private static let keyCodes: [String: CGKeyCode] = [
        "return": 36, "enter": 36, "tab": 48, "space": 49, "delete": 51, "backspace": 51,
        "escape": 53, "esc": 53, "left": 123, "right": 124, "down": 125, "up": 126,
        "home": 115, "end": 119, "pageup": 116, "pagedown": 121, "forwarddelete": 117,
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19,
        "3": 20, "4": 21, "6": 22, "5": 23, "9": 25, "7": 26, "8": 28, "0": 29, "o": 31,
        "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
    ]

    private static func pressKey(_ combo: String) -> Result {
        var flags: CGEventFlags = []
        var code: CGKeyCode?
        for part in combo.lowercased().split(separator: "+").map(String.init) {
            switch part {
            case "cmd", "command", "meta": flags.insert(.maskCommand)
            case "shift": flags.insert(.maskShift)
            case "opt", "option", "alt": flags.insert(.maskAlternate)
            case "ctrl", "control": flags.insert(.maskControl)
            case "fn": flags.insert(.maskSecondaryFn)
            default: code = keyCodes[part]
            }
        }
        guard let kc = code else { return Result(ok: false, error: "unknown key in combo: \(combo)") }
        for keyDown in [true, false] {
            guard let e = CGEvent(keyboardEventSource: nil, virtualKey: kc, keyDown: keyDown) else { continue }
            e.flags = flags
            e.post(tap: .cghidEventTap)
        }
        return Result(ok: true)
    }

    // MARK: Accessibility tree

    /// Walk the frontmost app's focused window and return interactive elements with
    /// their labels + center coordinates (points) — so the agent can target things
    /// semantically ("click Send") instead of guessing from pixels.
    private static func readUITree() -> String {
        guard let app = NSWorkspace.shared.frontmostApplication else { return "[]" }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        // Bound every AX message to this app (and the child elements created from it) so a hung or
        // beachballing target can't block up to the ~6 s default per call — a full walk of a slow
        // target would otherwise take minutes. This runs off the main actor now, but the timeout
        // still keeps a single read_ui bounded rather than open-ended.
        AXUIElementSetMessagingTimeout(axApp, 2)
        let root: AXUIElement
        if let focused = axAttr(axApp, kAXFocusedWindowAttribute),
           CFGetTypeID(focused) == AXUIElementGetTypeID() {
            root = unsafeBitCast(focused, to: AXUIElement.self)
        } else {
            root = axApp
        }
        var out: [[String: Any]] = []
        var count = 0
        axWalk(root, depth: 0, count: &count, into: &out)
        let obj: [String: Any] = ["app": app.localizedName ?? "", "elements": out]
        if let data = try? JSONSerialization.data(withJSONObject: obj),
           let s = String(data: data, encoding: .utf8) { return s }
        return "[]"
    }

    private static let interestingRoles: Set<String> = [
        "AXButton", "AXTextField", "AXTextArea", "AXLink", "AXCheckBox", "AXRadioButton",
        "AXPopUpButton", "AXMenuButton", "AXMenuItem", "AXSlider", "AXComboBox",
        "AXStaticText", "AXImage", "AXTabButton", "AXDisclosureTriangle",
    ]

    private static func axAttr(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success ? v : nil
    }

    private static func axString(_ el: AXUIElement, _ name: String) -> String? {
        axAttr(el, name) as? String
    }

    private static func axFrame(_ el: AXUIElement) -> CGRect? {
        guard let posV = axAttr(el, kAXPositionAttribute), let sizeV = axAttr(el, kAXSizeAttribute)
        else { return nil }
        guard CFGetTypeID(posV) == AXValueGetTypeID(),
              CFGetTypeID(sizeV) == AXValueGetTypeID() else { return nil }
        let posValue = unsafeBitCast(posV, to: AXValue.self)
        let sizeValue = unsafeBitCast(sizeV, to: AXValue.self)
        guard AXValueGetType(posValue) == .cgPoint,
              AXValueGetType(sizeValue) == .cgSize else { return nil }
        var pos = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(posValue, .cgPoint, &pos),
              AXValueGetValue(sizeValue, .cgSize, &size) else { return nil }
        return CGRect(origin: pos, size: size)
    }

    private static func axWalk(_ el: AXUIElement, depth: Int, count: inout Int, into: inout [[String: Any]]) {
        if depth > 14 || count > 250 { return }
        let role = axString(el, kAXRoleAttribute) ?? ""
        if interestingRoles.contains(role) {
            let label = axString(el, kAXTitleAttribute)
                ?? axString(el, kAXDescriptionAttribute)
                ?? (axAttr(el, kAXValueAttribute) as? String)
                ?? ""
            if !label.isEmpty, let f = axFrame(el), f.width > 1, f.height > 1 {
                into.append([
                    "role": role.replacingOccurrences(of: "AX", with: ""),
                    "label": String(label.prefix(80)),
                    "x": Int(f.midX), "y": Int(f.midY),
                ])
                count += 1
            }
        }
        if let children = axAttr(el, kAXChildrenAttribute) as? [AXUIElement] {
            for c in children { axWalk(c, depth: depth + 1, count: &count, into: &into) }
        }
    }

    // MARK: Document reading (attach-to-live-document)

    // MARK: Screen capture

    /// Capture the main display as a base64 PNG via ScreenCaptureKit. `CGDisplayCreateImage` is
    /// obsoleted as of the macOS 26 SDK, and SCK has no synchronous API — so this is async, and the
    /// caller awaits it off the main actor's critical path (the UI never blocks on the capture).
    static func screenshot() async -> Result {
        do {
            let content = try await SCShareableContent.current
            let mainID = CGMainDisplayID()
            guard let display = content.displays.first(where: { $0.displayID == mainID })
                    ?? content.displays.first else {
                return Result(ok: false, error: "no display available")
            }
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let cfg = SCStreamConfiguration()
            // Capture at POINT resolution (SCDisplay.width/height are points) so the image matches the
            // coordinate space click/move/drag use — same as the old CGDisplayBounds downscale.
            cfg.width = display.width
            cfg.height = display.height
            cfg.showsCursor = true
            let cg = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
            guard let data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else {
                return Result(ok: false, error: "png encode failed")
            }
            return Result(ok: true, image: data.base64EncodedString(), w: cg.width, h: cg.height)
        } catch {
            return Result(ok: false, error: "screen capture failed (grant Screen Recording): \(error.localizedDescription)")
        }
    }
}
