import Foundation
import WebKit

/// Security boundary for untrusted HTML produced by an agent or opened from a workspace.
///
/// Preview documents deliberately have no script, network, frame, form, or local-file access.
/// Inline styles and data-URL images are enough for useful static HTML/SVG previews without giving
/// generated content a path to read workspace files or exfiltrate data.
enum SafeHTMLPreview {
    /// What the document is being rendered *for*, which decides whether it may follow the app's
    /// appearance.
    ///
    /// The two are genuinely different jobs. A preview panel sitting inside a dark window should be
    /// dark, or it is a glaring white slab. A document being exported or printed must not be:
    /// `color-scheme: light dark` made an artifact exported in Dark Mode come out as light text on a
    /// dark background — a page of solid ink on paper, and a PDF that matches no other document the
    /// user owns (FR-177).
    ///
    /// This is a parameter rather than a fix at the export site because one builder serves three
    /// callers, and pinning it to light outright would fix the PDF by breaking both on-screen
    /// previews.
    enum Medium {
        /// Follows the app's appearance.
        case screen
        /// Always light, whatever the app is doing. Rendering for paper is not rendering for a screen.
        case paper

        var colorScheme: String {
            switch self {
            case .screen: return "light dark"
            case .paper: return "light"
            }
        }
    }

    static let contentSecurityPolicy = """
    default-src 'none'; img-src data:; style-src 'unsafe-inline'; font-src data:; \
    media-src data:; connect-src 'none'; script-src 'none'; frame-src 'none'; \
    child-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'
    """

    /// `renderedMermaidSVG` is the frozen output of `MermaidRenderer` (FR-334). It arrives
    /// separately because rendering is asynchronous and this builder is not: a caller that has a
    /// diagram passes it, and a caller that does not still gets a readable document.
    static func artifactDocument(
        for artifact: Artifact,
        medium: Medium = .screen,
        renderedMermaidSVG: String? = nil
    ) -> String {
        switch artifact.type {
        case "svg":
            return svgDocument(artifact.source, medium: medium)
        case "mermaid":
            // A rendered diagram is displayed as plain SVG, under the same `script-src 'none'`
            // document as every other artifact — the JavaScript ran offscreen and is already gone.
            if let renderedMermaidSVG {
                return svgDocument(renderedMermaidSVG, medium: medium)
            }
            // Nothing rendered yet, or the render failed. Showing the source beats showing nothing:
            // it is what the author wrote, and it is escaped, so it stays inert.
            return document(body: """
                <div class="preview-note">Mermaid source</div>
                <pre>\(escape(artifact.source))</pre>
                """, medium: medium)
        default:
            return document(body: artifact.source, medium: medium)
        }
    }

    /// The document shown while a diagram is still being rendered. Deliberately quiet — a diagram
    /// takes about a third of a second, and a spinner that appears for that long is just a flash.
    static func mermaidPlaceholderDocument(medium: Medium = .screen) -> String {
        document(body: "<div class=\"preview-note\">Rendering diagram…</div>", medium: medium)
    }

    /// A diagram that failed to render. Mermaid's parse errors name the offending line and token,
    /// which is the one thing that helps whoever has to fix the source, so it is shown above it.
    static func mermaidFailureDocument(
        source: String,
        message: String,
        medium: Medium = .screen
    ) -> String {
        document(body: """
            <div class="preview-note">This diagram could not be rendered — showing its source.</div>
            <pre class="preview-error">\(escape(message))</pre>
            <pre>\(escape(source))</pre>
            """, medium: medium)
    }

    private static func svgDocument(_ svg: String, medium: Medium) -> String {
        document(
            body: svg,
            bodyStyle: "margin:0;display:flex;justify-content:center;align-items:center;min-height:100vh",
            medium: medium)
    }

    static func fileDocument(_ source: String, medium: Medium = .screen) -> String {
        document(body: source, medium: medium)
    }

    static func document(body: String,
                         bodyStyle: String = "margin:0;padding:16px",
                         medium: Medium = .screen) -> String {
        """
        <!doctype html>
        <html>
        <head>
          <meta charset="utf-8">
          <meta http-equiv="Content-Security-Policy" content="\(contentSecurityPolicy)">
          <meta name="referrer" content="no-referrer">
          <style>
            :root { color-scheme: \(medium.colorScheme); }
            body { \(bodyStyle); font: 13px -apple-system, BlinkMacSystemFont, sans-serif; overflow-wrap: anywhere; }
            pre { white-space: pre-wrap; font: 12px ui-monospace, SFMono-Regular, Menlo, monospace; }
            .preview-note { margin-bottom: 12px; color: #777; font-size: 12px; }
            .preview-error { margin-bottom: 12px; color: #b3261e; }
            @media (prefers-color-scheme: dark) { .preview-error { color: #f2b8b5; } }
          </style>
        </head>
        <body>\(body)</body>
        </html>
        """
    }

    static func makeConfiguration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        return configuration
    }

    private static func escape(_ source: String) -> String {
        source
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}

/// A preview may render its initial `about:blank` document, but it may not follow links, redirects,
/// form submissions, downloads, or attempts to navigate to file/network URLs.
final class SafePreviewNavigationDelegate: NSObject, WKNavigationDelegate {
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard navigationAction.navigationType == .other else {
            decisionHandler(.cancel)
            return
        }
        let scheme = navigationAction.request.url?.scheme?.lowercased()
        decisionHandler(scheme == nil || scheme == "about" ? .allow : .cancel)
    }
}
