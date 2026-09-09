import Foundation
import WebKit

/// Turns Mermaid source into a static SVG, so the preview can show a diagram without ever becoming
/// a place where agent-authored content executes (FR-334).
///
/// The shape is deliberate. Mermaid is a JavaScript renderer, and the artifact preview is
/// script-free by construction: `SafeHTMLPreview.makeConfiguration()` sets
/// `allowsContentJavaScript = false` and its CSP says `script-src 'none'`. Rather than weaken that
/// for the document a person is looking at, the diagram is rendered *once* in a throwaway offscreen
/// web view and then frozen into SVG. What reaches the screen is markup, not a program.
///
/// Three properties do the security work, and each is load-bearing:
///
/// 1. **Content JavaScript is off in the renderer too.** Only `evaluateJavaScript` runs, which is
///    app-authored by definition. A `<script>` inside a document here does not execute — the same
///    guarantee `ArtifactPDFExport` already relies on when it measures `scrollHeight`.
/// 2. **The artifact source is never interpolated into code.** It is JSON-encoded into a string
///    literal and read by Mermaid as diagram text, never as markup or script.
/// 3. **The SVG is sanitized in the DOM before it is serialized.** Mermaid's `click ... href`
///    directive really does emit `<a xlink:href="https://…">` into the output, which would become a
///    live link in an exported file. Element and attribute scrubbing happens on a parsed tree, not
///    with string surgery on markup.
///
/// Rendering is one-shot per call: a fresh web view, loaded, injected, rendered, torn down. That
/// costs roughly a third of a second, which is why results are cached — a repeat view is instant,
/// and no two artifacts ever share a JavaScript context.
@MainActor
enum MermaidRenderer {
    /// Mermaid's own theme names. The preview follows the app's appearance; paper is always light.
    enum Theme: String {
        case light = "default"
        case dark = "dark"
    }

    /// Well above any hand-written diagram, while bounding what gets copied into the renderer.
    static let maximumSourceByteCount = 512 * 1_024

    /// Covers injecting the bundled renderer, laying the diagram out, and serializing it.
    /// `nonisolated` so it can serve as a default argument, which is evaluated at the call site.
    nonisolated static let defaultRenderTimeout: TimeInterval = 20

    /// Rendered diagrams are a pure function of (source, theme), so they cache safely by content.
    /// Artifacts update live and a preview re-renders on every appearance flip, so the cache is
    /// bounded rather than left to grow with the conversation.
    private static let maximumCacheEntries = 32

    private struct CacheKey: Hashable {
        let source: String
        let theme: String
    }

    private static var cache: [CacheKey: String] = [:]
    private static var cacheOrder: [CacheKey] = []

    /// The synchronous answer, for a view that must decide what to draw *now*. `nil` means "not
    /// rendered yet", not "cannot be rendered".
    static func cachedSVG(for source: String, theme: Theme) -> String? {
        cache[CacheKey(source: source, theme: theme.rawValue)]
    }

    static func svg(for source: String, theme: Theme) async throws -> String {
        try await svg(for: source, theme: theme, renderer: WebKitMermaidSVGRenderer())
    }

    /// Seam for tests: the caching behavior is the same whoever does the rendering.
    static func svg(
        for source: String,
        theme: Theme,
        renderer: any MermaidSVGRendering
    ) async throws -> String {
        let key = CacheKey(source: source, theme: theme.rawValue)
        if let hit = cache[key] { return hit }
        let rendered = try await renderSVG(source: source, theme: theme, renderer: renderer)
        store(rendered, for: key)
        return rendered
    }

    /// Seam for tests: the policy (size limit, timeout, validation) is exercised without WebKit.
    static func renderSVG(
        source: String,
        theme: Theme,
        renderer: any MermaidSVGRendering,
        renderTimeout: TimeInterval = defaultRenderTimeout
    ) async throws -> String {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw MermaidRenderError.emptySource }
        guard source.utf8.count <= maximumSourceByteCount else {
            throw MermaidRenderError.sourceTooLarge
        }

        let timeoutNanoseconds = UInt64(min(max(renderTimeout, 0.001), 120) * 1_000_000_000)
        let svg = try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask { @MainActor in
                try await renderer.renderSVG(source: source, theme: theme.rawValue)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
                throw MermaidRenderError.renderTimedOut
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw CancellationError() }
            return first
        }

        // The sanitizer already ran in the DOM. This is the cheap independent check that it did:
        // if anything executable survived, refuse the render rather than display it. Failing closed
        // costs a diagram; failing open puts agent-authored script in front of a person.
        try validate(svg)
        return svg
    }

    /// Rejects anything that should not exist in a frozen diagram. Deliberately conservative: these
    /// substrings do not appear in Mermaid's own output, so a match means the DOM scrub missed
    /// something and the result is not trustworthy.
    static func validate(_ svg: String) throws {
        guard svg.contains("<svg") else { throw MermaidRenderError.notSVG }
        let collapsed = svg.lowercased().filter { !$0.isWhitespace }
        for forbidden in ["<script", "javascript:", "<iframe", "<foreignobject", "@import",
                          "<object", "<embed", "href=\"http", "href='http"] {
            if collapsed.contains(forbidden) {
                throw MermaidRenderError.unsafeOutput(forbidden)
            }
        }
        // Catches `onload=`, `onerror=`, `onclick=` and every other inline handler in one rule. It
        // runs on the original text, not `collapsed`: an attribute is recognised by the separator in
        // front of it, and stripping whitespace is exactly what destroys that.
        //
        // The shape is deliberately narrow. A looser `on[a-z-]+=` also matches ordinary label text —
        // a node called `x one=2` serializes to `>x one=2<` and would have its diagram refused. Real
        // handler names have at least three letters after `on` and a quoted value; `one=` has
        // neither.
        let lowercased = svg.lowercased()
        if lowercased.range(of: #"\son[a-z]{3,}\s*=\s*["']"#, options: .regularExpression) != nil {
            throw MermaidRenderError.unsafeOutput("inline event handler")
        }
    }

    static func resetCacheForTesting() {
        cache.removeAll()
        cacheOrder.removeAll()
    }

    private static func store(_ svg: String, for key: CacheKey) {
        if cache[key] == nil { cacheOrder.append(key) }
        cache[key] = svg
        while cacheOrder.count > maximumCacheEntries {
            cache.removeValue(forKey: cacheOrder.removeFirst())
        }
    }
}

enum MermaidRenderError: LocalizedError, Equatable {
    case emptySource
    case sourceTooLarge
    case rendererUnavailable
    case navigationDidNotStart
    case navigationFailed(String)
    case webContentProcessTerminated
    case renderTimedOut
    case diagramFailed(String)
    case notSVG
    case unsafeOutput(String)

    var errorDescription: String? {
        switch self {
        case .emptySource:
            return "This diagram has no source to render."
        case .sourceTooLarge:
            return "This diagram is too large to render safely."
        case .rendererUnavailable:
            return "The bundled diagram renderer is missing from this build."
        // WebKit's own wording describes a web view, which says nothing a person can act on. The
        // payload is kept for logs and tests and deliberately not surfaced.
        case .navigationDidNotStart, .navigationFailed:
            return "The diagram renderer could not be loaded."
        case .webContentProcessTerminated:
            return "The diagram renderer stopped before the diagram was finished."
        case .renderTimedOut:
            return "This diagram took too long to render."
        // Mermaid's parse errors name the line and token, which is exactly what an author needs.
        case .diagramFailed(let message):
            return message
        case .notSVG, .unsafeOutput:
            return "The diagram renderer did not produce a usable diagram."
        }
    }
}

/// A narrow seam around WebKit so render policy can be tested without a web content process.
@MainActor
protocol MermaidSVGRendering: AnyObject {
    func renderSVG(source: String, theme: String) async throws -> String
}

/// One-shot Mermaid renderer. A fresh instance owns a fresh offscreen web view per render, so no
/// two artifacts are ever laid out in the same JavaScript context.
@MainActor
final class WebKitMermaidSVGRenderer: NSObject, MermaidSVGRendering, WKNavigationDelegate {
    /// Mermaid measures text against a real layout, so the view needs a plausible size. It is never
    /// added to a window — only the serialized SVG escapes.
    private static let canvasSize = CGSize(width: 1_200, height: 900)
    private static let pollInterval: TimeInterval = 0.05

    private let safeNavigationDelegate = SafePreviewNavigationDelegate()
    private var webView: WKWebView?
    private var loadContinuation: CheckedContinuation<Void, Error>?

    /// Overridable only so tests can drive the real WebKit path: `Bundle.main` inside an XCTest
    /// process is the test runner, not the app, so the bundled copy is not on that search path.
    private let mermaidJSOverride: String?

    init(mermaidJS: String? = nil) {
        self.mermaidJSOverride = mermaidJS
        super.init()
    }

    /// The vendored renderer, pinned in `app/Resources/mermaid.min.js` and copied into the bundle by
    /// `build-app.sh` and `dev.sh`. Bundled rather than fetched: a preview must not reach the
    /// network, and a diagram must not depend on a CDN being up.
    static func bundledMermaidJS() -> String? {
        guard let url = Bundle.main.url(forResource: "mermaid", withExtension: "min.js"),
              let js = try? String(contentsOf: url, encoding: .utf8),
              !js.isEmpty else { return nil }
        return js
    }

    func renderSVG(source: String, theme: String) async throws -> String {
        guard let mermaidJS = mermaidJSOverride ?? Self.bundledMermaidJS() else {
            throw MermaidRenderError.rendererUnavailable
        }
        defer { teardown() }

        let webView = makeWebView()
        try await load(webView)

        // App-authored injection. Content JavaScript is off, so nothing in the loaded document ran;
        // these two are the only code in this context, and neither is derived from the artifact.
        _ = try? await webView.evaluateJavaScript(mermaidJS)
        _ = try? await webView.evaluateJavaScript(Self.sanitizerJS)
        let injected = try? await webView.evaluateJavaScript("typeof globalThis.mermaid")
        guard (injected as? String) == "object" else {
            throw MermaidRenderError.rendererUnavailable
        }

        // The artifact source crosses into JavaScript as a JSON string literal and nothing else.
        // `callAsyncJavaScript` would read better, but it resolves to Void in this configuration,
        // so the render is kicked off and its outcome polled from a global instead.
        let arguments = try JSONSerialization.data(withJSONObject: [source, theme])
        guard let argumentLiteral = String(data: arguments, encoding: .utf8) else {
            throw MermaidRenderError.diagramFailed("This diagram's source could not be read.")
        }
        _ = try? await webView.evaluateJavaScript(Self.renderKickoffJS(arguments: argumentLiteral))

        return try await pollForResult(webView)
    }

    private func makeWebView() -> WKWebView {
        let configuration = SafeHTMLPreview.makeConfiguration()
        let webView = WKWebView(
            frame: CGRect(origin: .zero, size: Self.canvasSize),
            configuration: configuration)
        webView.navigationDelegate = self
        self.webView = webView
        return webView
    }

    /// The load phase resumes from a `WKNavigationDelegate` callback, and a wedged web content
    /// process never delivers one. Without the cancellation handler that is not merely slow: a task
    /// group awaits its children at scope exit, so the timeout in `MermaidRenderer.renderSVG` would
    /// fire and then block forever on this suspended child. Cancellation has to reach the
    /// continuation for the timeout to mean anything.
    private func load(_ webView: WKWebView) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                loadContinuation = continuation
                // An app-authored host page. It holds no artifact content, so there is nothing here
                // for the CSP to contain — it is belt and braces over `allowsContentJavaScript`.
                let document = """
                <!doctype html>
                <html>
                <head>
                  <meta charset="utf-8">
                  <meta http-equiv="Content-Security-Policy" content="\(SafeHTMLPreview.contentSecurityPolicy)">
                  <meta name="referrer" content="no-referrer">
                </head>
                <body></body>
                </html>
                """
                guard webView.loadHTMLString(document, baseURL: nil) != nil else {
                    finishLoad(.failure(MermaidRenderError.navigationDidNotStart))
                    return
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.finishLoad(.failure(CancellationError()))
            }
        }
    }

    private func pollForResult(_ webView: WKWebView) async throws -> String {
        while true {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: UInt64(Self.pollInterval * 1_000_000_000))
            let raw = try? await webView.evaluateJavaScript(
                "globalThis.__mechanicianMermaidResult === null ? '' : String(globalThis.__mechanicianMermaidResult)")
            guard let outcome = raw as? String, !outcome.isEmpty else { continue }
            if outcome.hasPrefix("OK:") { return String(outcome.dropFirst(3)) }
            throw MermaidRenderError.diagramFailed(
                String(outcome.dropFirst(outcome.hasPrefix("ERR:") ? 4 : 0)))
        }
    }

    private func finishLoad(_ result: Result<Void, Error>) {
        guard let continuation = loadContinuation else { return }
        loadContinuation = nil
        continuation.resume(with: result)
    }

    private func teardown() {
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView = nil
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        safeNavigationDelegate.webView(
            webView, decidePolicyFor: navigationAction, decisionHandler: decisionHandler)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === self.webView else { return }
        finishLoad(.success(()))
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard webView === self.webView else { return }
        finishLoad(.failure(MermaidRenderError.navigationFailed(error.localizedDescription)))
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        guard webView === self.webView else { return }
        finishLoad(.failure(MermaidRenderError.navigationFailed(error.localizedDescription)))
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard webView === self.webView else { return }
        finishLoad(.failure(MermaidRenderError.webContentProcessTerminated))
    }
}

extension WebKitMermaidSVGRenderer {
    /// Scrubs the rendered tree before it is serialized.
    ///
    /// This runs on a parsed DOM rather than over markup, because the thing being removed —
    /// `<a xlink:href>` from Mermaid's `click` directive, inline handlers, embedded HTML — is
    /// structure, and string surgery on structure is how sanitizers get bypassed.
    static let sanitizerJS = """
    (function () {
      var BLOCKED_ELEMENTS = ['script', 'foreignobject', 'iframe', 'object', 'embed', 'animate',
                              'animatemotion', 'animatetransform', 'set', 'handler', 'listener'];

      // A reference survives only if it points inside this document or is an inline data URL.
      // Everything else — http(s), javascript:, file:, protocol-relative — is dropped.
      function safeRef(value) {
        if (value === null || value === undefined) return false;
        var v = String(value).replace(/[\\s]/g, '');
        return v.charAt(0) === '#' || v.slice(0, 5).toLowerCase() === 'data:';
      }

      function scrub(node) {
        var children = Array.prototype.slice.call(node.childNodes || []);
        for (var i = 0; i < children.length; i++) {
          var child = children[i];
          if (child.nodeType !== 1) continue;
          var name = (child.localName || child.nodeName || '').toLowerCase();
          if (BLOCKED_ELEMENTS.indexOf(name) !== -1) {
            child.parentNode.removeChild(child);
            continue;
          }
          var attrs = Array.prototype.slice.call(child.attributes || []);
          for (var j = 0; j < attrs.length; j++) {
            var attr = attrs[j];
            var an = attr.name.toLowerCase();
            var av = String(attr.value);
            if (an.indexOf('on') === 0) { child.removeAttribute(attr.name); continue; }
            if (an === 'href' || an === 'xlink:href' || an.slice(-5) === ':href') {
              if (!safeRef(av)) { child.removeAttribute(attr.name); }
              continue;
            }
            if (av.replace(/[\\s]/g, '').toLowerCase().indexOf('javascript:') !== -1) {
              child.removeAttribute(attr.name);
            }
          }
          if (name === 'style' && child.textContent && child.textContent.indexOf('@import') !== -1) {
            child.textContent = child.textContent.replace(/@import[^;}]*;?/gi, '');
          }
          scrub(child);
        }
      }

      // The HTML parser, not DOMParser's XML mode: Mermaid emits `xlink:href` without declaring the
      // prefix, which is fatal in `image/svg+xml` and rejects the whole document. HTML foreign
      // content parses it, preserves SVG attribute casing (`viewBox`), and executes nothing.
      globalThis.__mechSanitizeSVG = function (svgText) {
        var host = document.createElement('div');
        host.innerHTML = String(svgText);
        var root = host.firstElementChild;
        if (!root) return null;
        if ((root.localName || '').toLowerCase() !== 'svg') return null;
        scrub(host);
        root = host.firstElementChild;
        if (!root) return null;
        return new XMLSerializer().serializeToString(root);
      };
    })();
    """

    /// `arguments` is a JSON array literal — `[source, theme]` — so neither value is ever spliced
    /// into code as syntax.
    static func renderKickoffJS(arguments: String) -> String {
        """
        globalThis.__mechanicianMermaidResult = null;
        (function () {
          var args = \(arguments);
          try {
            mermaid.initialize({
              startOnLoad: false,
              securityLevel: 'strict',
              htmlLabels: false,
              flowchart: { htmlLabels: false },
              class: { htmlLabels: false },
              deterministicIds: true,
              theme: args[1],
              fontFamily: '-apple-system, BlinkMacSystemFont, system-ui, sans-serif'
            });
            mermaid.render('mechanician-diagram', args[0]).then(function (result) {
              var svg = globalThis.__mechSanitizeSVG(result.svg);
              globalThis.__mechanicianMermaidResult =
                (svg === null) ? 'ERR:This diagram could not be rendered.' : 'OK:' + svg;
            }).catch(function (error) {
              globalThis.__mechanicianMermaidResult =
                'ERR:' + (error && error.message ? error.message : String(error));
            });
          } catch (error) {
            globalThis.__mechanicianMermaidResult =
              'ERR:' + (error && error.message ? error.message : String(error));
          }
        })();
        1
        """
    }
}
