import Foundation
import PDFKit
import WebKit

/// A narrow seam around WebKit so the artifact-to-document and document-to-file behavior can be
/// tested without launching a web content process.
@MainActor
protocol ArtifactHTMLPDFRendering: AnyObject {
    func renderPDF(document: String) async throws -> Data
}

enum ArtifactPDFExportError: LocalizedError, Equatable {
    case unsupportedArtifactType(String)
    case navigationDidNotStart
    case navigationFailed(String)
    case renderingFailed(String)
    case webContentProcessTerminated
    case sourceTooLarge
    case contentTooLarge
    case renderTimedOut
    case invalidPDFData

    var errorDescription: String? {
        switch self {
        case .unsupportedArtifactType(let type):
            return "Save as PDF currently supports HTML artifacts only, not \(type)."
        case .navigationDidNotStart:
            return "The HTML artifact could not be loaded for PDF export."
        // The payloads are kept for logs and tests, and deliberately not shown: they are WebKit's
        // words about a web view, which say nothing a person can act on.
        case .navigationFailed:
            return "The HTML artifact could not be loaded for PDF export."
        case .renderingFailed:
            return "The HTML artifact could not be rendered for PDF export."
        case .webContentProcessTerminated:
            return "The HTML renderer stopped before PDF export finished."
        case .sourceTooLarge:
            return "The HTML artifact source is too large to render safely as a PDF."
        case .contentTooLarge:
            return "The HTML artifact is too large to render safely as one PDF."
        case .renderTimedOut:
            return "The HTML artifact took too long to render as a PDF."
        case .invalidPDFData:
            return "The HTML renderer did not produce a valid PDF."
        }
    }
}

/// HTML-first PDF export for artifacts (FR-145).
///
/// The exported document intentionally comes from `SafeHTMLPreview`, rather than loading the
/// artifact source directly, so PDF generation has the same script/network/file restrictions as
/// the on-screen preview. Other artifact types remain explicit future work.
enum ArtifactPDFExport {
    private static let pdfHeader = Data("%PDF-".utf8)

    /// Keep untrusted generated HTML from being copied into an arbitrarily large WebKit document.
    /// Five MiB is well above normal artifact output while bounding the renderer's input allocation.
    static let maximumSourceByteCount = 5 * 1_024 * 1_024

    /// Bounds navigation, layout measurement, and PDF creation as one operation.
    static let defaultRenderTimeout: TimeInterval = 30

    static func filename(for artifact: Artifact) -> String {
        let nativeFilename = ArtifactFileExport.filename(for: artifact)
        let base = (nativeFilename as NSString).deletingPathExtension
        return base.lowercased().hasSuffix(".pdf") ? base : base + ".pdf"
    }

    @MainActor
    static func pdfData(for artifact: Artifact) async throws -> Data {
        try await pdfData(for: artifact, renderer: WebKitArtifactPDFRenderer())
    }

    @MainActor
    static func pdfData(
        for artifact: Artifact,
        renderer: any ArtifactHTMLPDFRendering,
        renderTimeout: TimeInterval = defaultRenderTimeout
    ) async throws -> Data {
        guard artifact.type.lowercased() == "html" else {
            throw ArtifactPDFExportError.unsupportedArtifactType(artifact.type)
        }
        guard artifact.source.utf8.count <= maximumSourceByteCount else {
            throw ArtifactPDFExportError.sourceTooLarge
        }

        // `.paper`, not the default `.screen`: an export is a document, not a panel. Exporting in
        // Dark Mode used to produce light text on a dark background — a page of solid ink on paper
        // (FR-177). The on-screen previews keep following the app's appearance.
        let document = SafeHTMLPreview.artifactDocument(for: artifact, medium: .paper)
        let timeoutNanoseconds = UInt64(
            min(max(renderTimeout, 0.001), 120) * 1_000_000_000)
        let data = try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask { @MainActor in
                try await renderer.renderPDF(document: document)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
                throw ArtifactPDFExportError.renderTimedOut
            }
            defer { group.cancelAll() }
            guard let firstResult = try await group.next() else {
                throw CancellationError()
            }
            return firstResult
        }
        guard data.starts(with: pdfHeader),
              let document = PDFDocument(data: data),
              document.pageCount > 0 else {
            throw ArtifactPDFExportError.invalidPDFData
        }
        return data
    }

    @MainActor
    static func write(_ artifact: Artifact, to url: URL) async throws {
        try await write(artifact, to: url, renderer: WebKitArtifactPDFRenderer())
    }

    @MainActor
    static func write(
        _ artifact: Artifact,
        to url: URL,
        renderer: any ArtifactHTMLPDFRendering
    ) async throws {
        let data = try await pdfData(for: artifact, renderer: renderer)
        try data.write(to: url, options: .atomic)
    }
}

/// One-shot, nonpersistent HTML renderer. A fresh instance owns a fresh web view for each export.
///
/// Loading and PDF creation are deliberately separate awaited phases. Calling `createPDF` before
/// `webView(_:didFinish:)` can capture the initial `about:blank` page instead of the artifact.
@MainActor
final class WebKitArtifactPDFRenderer: NSObject, ArtifactHTMLPDFRendering, WKNavigationDelegate {
    private static let pageSize = CGSize(width: 612, height: 792)
    private static let maximumContentHeight: CGFloat = 100_000

    private enum Phase {
        case idle
        case loading
        case measuring
        case creatingPDF
    }

    private let safeNavigationDelegate = SafePreviewNavigationDelegate()
    private let renderTimeout: TimeInterval
    private var webView: WKWebView?
    private var renderContinuation: CheckedContinuation<Data, Error>?
    private var renderTimeoutTask: Task<Void, Never>?
    private var activeRenderID: UUID?
    private var phase: Phase = .idle

    init(renderTimeout: TimeInterval = ArtifactPDFExport.defaultRenderTimeout) {
        self.renderTimeout = min(max(renderTimeout, 0.001), 120)
        super.init()
    }

    func renderPDF(document: String) async throws -> Data {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Data, Error>) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                beginRender(document: document, continuation: continuation)
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.finishRender(.failure(CancellationError()))
            }
        }
    }

    private func beginRender(
        document: String,
        continuation: CheckedContinuation<Data, Error>
    ) {
        guard renderContinuation == nil else {
            continuation.resume(throwing: ArtifactPDFExportError.renderingFailed(
                "A PDF render is already in progress."))
            return
        }

        let configuration = SafeHTMLPreview.makeConfiguration()
        let webView = WKWebView(
            frame: CGRect(origin: .zero, size: Self.pageSize),
            configuration: configuration)
        webView.navigationDelegate = self
        // Belt and braces with the `.paper` stylesheet above. `color-scheme: light` is what actually
        // fixes this, but the render view still inherits `NSApp.appearance`, and anything that reads
        // the effective appearance rather than the declaration would land back in Dark Mode. Nothing
        // drawn for paper should be able to see what the app looks like.
        webView.appearance = NSAppearance(named: .aqua)
        self.webView = webView
        renderContinuation = continuation
        phase = .loading
        let renderID = UUID()
        activeRenderID = renderID
        let timeoutNanoseconds = UInt64(renderTimeout * 1_000_000_000)
        renderTimeoutTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
            } catch {
                return
            }
            guard let self, self.activeRenderID == renderID else { return }
            self.finishRender(.failure(ArtifactPDFExportError.renderTimedOut))
        }

        guard webView.loadHTMLString(document, baseURL: nil) != nil else {
            finishRender(.failure(ArtifactPDFExportError.navigationDidNotStart))
            return
        }
    }

    private func measureAndCreatePDF(in webView: WKWebView) {
        guard webView === self.webView,
              phase == .loading,
              let renderID = activeRenderID else { return }
        phase = .measuring

        // `WKPDFConfiguration.rect = webView.bounds` silently clips everything below the initial
        // viewport. Ask the loaded, script-disabled document for its scroll height using a fixed
        // app-authored expression, then capture the complete page. Keep the dimension bounded so
        // hostile generated CSS cannot request an unbounded bitmap/PDF allocation.
        webView.evaluateJavaScript(
            "Math.max(document.body.scrollHeight, document.documentElement.scrollHeight)"
        ) { [weak self] measured, error in
            let contentHeight = (measured as? NSNumber)?.doubleValue
            let errorMessage = error?.localizedDescription
            Task { @MainActor [weak self] in
                self?.completeMeasurement(
                    contentHeight: contentHeight,
                    errorMessage: errorMessage,
                    renderID: renderID)
            }
        }
    }

    private func completeMeasurement(
        contentHeight measuredContentHeight: Double?,
        errorMessage: String?,
        renderID: UUID
    ) {
        guard activeRenderID == renderID,
              phase == .measuring,
              let webView else { return }
        if let errorMessage {
            finishRender(.failure(ArtifactPDFExportError.renderingFailed(errorMessage)))
            return
        }
        let contentHeight = measuredContentHeight ?? Double(Self.pageSize.height)
        guard contentHeight.isFinite,
              contentHeight >= 0,
              contentHeight <= Double(Self.maximumContentHeight) else {
            finishRender(.failure(ArtifactPDFExportError.contentTooLarge))
            return
        }

        let pdfConfiguration = WKPDFConfiguration()
        pdfConfiguration.rect = CGRect(
            origin: .zero,
            size: CGSize(
                width: Self.pageSize.width,
                height: max(Self.pageSize.height, ceil(contentHeight))))
        phase = .creatingPDF
        webView.createPDF(configuration: pdfConfiguration) { [weak self] result in
            let data: Data?
            let errorMessage: String?
            switch result {
            case .success(let renderedData):
                data = renderedData
                errorMessage = nil
            case .failure(let error):
                data = nil
                errorMessage = error.localizedDescription
            }
            Task { @MainActor [weak self] in
                guard let self,
                      self.activeRenderID == renderID,
                      self.phase == .creatingPDF else { return }
                if let data {
                    self.finishRender(.success(data))
                } else {
                    self.finishRender(.failure(
                        ArtifactPDFExportError.renderingFailed(
                            errorMessage ?? "WebKit did not return PDF data.")))
                }
            }
        }
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        safeNavigationDelegate.webView(
            webView,
            decidePolicyFor: navigationAction,
            decisionHandler: decisionHandler)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        measureAndCreatePDF(in: webView)
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        guard webView === self.webView, phase == .loading else { return }
        finishRender(.failure(
            ArtifactPDFExportError.navigationFailed(error.localizedDescription)))
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        guard webView === self.webView, phase == .loading else { return }
        finishRender(.failure(
            ArtifactPDFExportError.navigationFailed(error.localizedDescription)))
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard webView === self.webView else { return }
        finishRender(.failure(ArtifactPDFExportError.webContentProcessTerminated))
    }

    /// Every terminal path (success, WebKit failure, timeout, or task cancellation) converges here.
    /// Clearing the continuation before stopping WebKit makes late delegate callbacks harmless and
    /// guarantees the checked continuation is resumed exactly once.
    private func finishRender(_ result: Result<Data, Error>) {
        guard let continuation = renderContinuation else { return }
        renderContinuation = nil
        activeRenderID = nil
        phase = .idle
        let timeoutTask = renderTimeoutTask
        renderTimeoutTask = nil
        timeoutTask?.cancel()
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView = nil
        continuation.resume(with: result)
    }
}
