import AppKit
import Darwin
import PDFKit
import XCTest
@testable import Mechanician

private actor FilePreviewLoadGate {
    private var continuations: [String: CheckedContinuation<FilePreview, Never>] = [:]

    func load(_ url: URL) async -> FilePreview {
        await withCheckedContinuation { continuation in
            continuations[url.path] = continuation
        }
    }

    func contains(_ url: URL) -> Bool {
        continuations[url.path] != nil
    }

    func resolve(_ url: URL, with preview: FilePreview) {
        continuations.removeValue(forKey: url.path)?.resume(returning: preview)
    }
}

@MainActor
final class FileBrowserPreviewTests: XCTestCase {
    private func fixture(named name: String, data: Data = Data()) throws -> (directory: URL, file: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileBrowserPreviewTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(name)
        try data.write(to: file)
        return (directory, file)
    }

    private func waitUntilRegistered(_ url: URL, in gate: FilePreviewLoadGate) async {
        for _ in 0 ..< 1_000 {
            if await gate.contains(url) { return }
            await Task.yield()
        }
        XCTFail("Preview load was not registered for \(url.path)")
    }

    private func waitForText(
        _ expected: String,
        from loader: FilePreviewLoader
    ) async -> Bool {
        for _ in 0 ..< 1_000 {
            if case .text(let content) = loader.preview, content.text == expected { return true }
            await Task.yield()
        }
        return false
    }

    func testFIFOIsRejectedWithoutWaitingForAWriter() throws {
        let made = try fixture(named: "pipe")
        try FileManager.default.removeItem(at: made.file)
        defer { try? FileManager.default.removeItem(at: made.directory) }
        let status = made.file.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.mkfifo(path, S_IRUSR | S_IWUSR)
        }
        XCTAssertEqual(status, 0)

        XCTAssertThrowsError(try FilePreviewReader.text(at: made.file)) { error in
            guard case FileBrowserPreviewError.notRegularFile = error else {
                return XCTFail("expected notRegularFile, got \(error)")
            }
        }
    }

    func testCharacterDeviceIsRejectedAsANonRegularFile() {
        XCTAssertThrowsError(try FilePreviewReader.text(
            at: URL(fileURLWithPath: "/dev/null"))) { error in
            guard case FileBrowserPreviewError.notRegularFile = error else {
                return XCTFail("expected notRegularFile, got \(error)")
            }
        }
    }

    func testOversizedSparseTextFileIsRejectedBeforeItIsRead() throws {
        let made = try fixture(named: "oversized.txt")
        defer { try? FileManager.default.removeItem(at: made.directory) }
        let descriptor = made.file.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.open(path, O_WRONLY | O_CLOEXEC)
        }
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        XCTAssertEqual(
            Darwin.ftruncate(descriptor, off_t(FilePreviewReader.maximumTextSourceBytes)),
            0)
        Darwin.close(descriptor)

        XCTAssertThrowsError(try FilePreviewReader.text(at: made.file)) { error in
            guard case FileBrowserPreviewError.tooLarge = error else {
                return XCTFail("expected tooLarge, got \(error)")
            }
        }
    }

    func testTextPreviewHasAnExplicitCharacterRenderBudget() throws {
        let source = String(
            repeating: "a",
            count: FilePreviewReader.maximumRenderedCharacters + 5_000)
        let made = try fixture(named: "large.md", data: Data(source.utf8))
        defer { try? FileManager.default.removeItem(at: made.directory) }

        let content = try FilePreviewReader.text(at: made.file)

        XCTAssertTrue(content.isTruncated)
        XCTAssertEqual(content.text.count, FilePreviewReader.maximumRenderedCharacters)
        XCTAssertEqual(content.text, String(source.prefix(FilePreviewReader.maximumRenderedCharacters)))
    }

    func testMarkdownUsesATighterRichRenderBudget() async throws {
        let source = "# " + String(
            repeating: "a",
            count: FilePreviewReader.maximumMarkdownRenderedCharacters + 5_000)
        let made = try fixture(named: "large.md", data: Data(source.utf8))
        defer { try? FileManager.default.removeItem(at: made.directory) }

        let preview = await FilePreviewReader.preview(at: made.file)

        guard case .markdown(let content) = preview else {
            return XCTFail("expected a Markdown preview, got \(preview)")
        }
        XCTAssertTrue(content.isTruncated)
        XCTAssertEqual(content.text.count, FilePreviewReader.maximumMarkdownRenderedCharacters)
    }

    func testMarkdownUsesALineBudgetForManyTinyBlocks() async throws {
        let source = String(
            repeating: "- x\n",
            count: FilePreviewReader.maximumMarkdownRenderedLines * 10)
        let made = try fixture(named: "many-blocks.md", data: Data(source.utf8))
        defer { try? FileManager.default.removeItem(at: made.directory) }

        let preview = await FilePreviewReader.preview(at: made.file)

        guard case .markdown(let content) = preview else {
            return XCTFail("expected a Markdown preview, got \(preview)")
        }
        XCTAssertTrue(content.isTruncated)
        XCTAssertLessThanOrEqual(
            content.text.split(separator: "\n", omittingEmptySubsequences: false).count,
            FilePreviewReader.maximumMarkdownRenderedLines)
    }

    func testVeryWideMarkdownTableFallsBackToOnePlainTextView() async throws {
        let columns = FilePreviewReader.maximumMarkdownTableColumns + 10
        let header = "|" + Array(repeating: "heading", count: columns).joined(separator: "|") + "|"
        let divider = "|" + Array(repeating: "---", count: columns).joined(separator: "|") + "|"
        let made = try fixture(
            named: "wide-table.md",
            data: Data("\(header)\n\(divider)".utf8))
        defer { try? FileManager.default.removeItem(at: made.directory) }

        let preview = await FilePreviewReader.preview(at: made.file)

        guard case .text(let content) = preview else {
            return XCTFail("A very wide Markdown table must use the bounded plain-text renderer")
        }
        XCTAssertTrue(content.text.contains("heading"))
    }

    func testByteBudgetDoesNotTurnASplitUTF8ScalarIntoAnUnsupportedPreview() throws {
        let emojiCount = FilePreviewReader.maximumRenderedBytes / 4
        let source = "x" + String(repeating: "🙂", count: emojiCount)
        let made = try fixture(named: "unicode.txt", data: Data(source.utf8))
        defer { try? FileManager.default.removeItem(at: made.directory) }

        let content = try FilePreviewReader.text(at: made.file)

        XCTAssertTrue(content.isTruncated)
        XCTAssertEqual(content.text.first, "x")
        XCTAssertEqual(content.text.count, emojiCount)
        XCTAssertLessThanOrEqual(content.text.utf8.count, FilePreviewReader.maximumRenderedBytes)
    }

    func testNULBearingTextIsRejectedAsBinary() throws {
        let made = try fixture(named: "binary.txt", data: Data([0x61, 0x00, 0x62]))
        defer { try? FileManager.default.removeItem(at: made.directory) }

        XCTAssertThrowsError(try FilePreviewReader.text(at: made.file)) { error in
            guard case FileBrowserPreviewError.notUTF8 = error else {
                return XCTFail("expected notUTF8, got \(error)")
            }
        }
    }

    func testImagePreviewDecodesOnlyABoundedThumbnail() async throws {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: FilePreviewReader.maximumImageDimension * 2,
            pixelsHigh: 64,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0))
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let made = try fixture(named: "wide.png", data: data)
        defer { try? FileManager.default.removeItem(at: made.directory) }

        let preview = await FilePreviewReader.preview(at: made.file)

        guard case .image(let image) = preview else {
            return XCTFail("expected an image preview, got \(preview)")
        }
        XCTAssertLessThanOrEqual(
            max(image.size.width, image.size.height),
            CGFloat(FilePreviewReader.maximumImageDimension))
    }

    func testPDFPreviewRejectsDocumentsPastTheInlinePageBudget() async throws {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 1,
            pixelsHigh: 1,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0))
        let pageImage = NSImage(size: NSSize(width: 1, height: 1))
        pageImage.addRepresentation(bitmap)
        let document = PDFDocument()
        for index in 0 ... FilePreviewReader.maximumPDFPages {
            document.insert(try XCTUnwrap(PDFPage(image: pageImage)), at: index)
        }
        let data = try XCTUnwrap(document.dataRepresentation())
        let made = try fixture(named: "too-many-pages.pdf", data: data)
        defer { try? FileManager.default.removeItem(at: made.directory) }

        let preview = await FilePreviewReader.preview(at: made.file)

        guard case .unsupported = preview else {
            return XCTFail("A PDF over the page budget must fall back to Quick Look")
        }
    }

    func testSupersededLoaderCannotPublishAfterIgnoringCancellation() async {
        let first = URL(fileURLWithPath: "/tmp/first.txt")
        let second = URL(fileURLWithPath: "/tmp/second.txt")
        let gate = FilePreviewLoadGate()
        let loader = FilePreviewLoader(loader: { await gate.load($0) })

        loader.select(first)
        await waitUntilRegistered(first, in: gate)
        loader.select(second)
        await waitUntilRegistered(second, in: gate)

        await gate.resolve(
            first,
            with: .text(FilePreviewTextContent(text: "stale", isTruncated: false)))
        await Task.yield()
        guard case .loading = loader.preview else {
            return XCTFail("A superseded result replaced the newer in-flight preview")
        }

        await gate.resolve(
            second,
            with: .text(FilePreviewTextContent(text: "current", isTruncated: false)))
        for _ in 0 ..< 1_000 {
            if case .text(let content) = loader.preview, content.text == "current" { return }
            await Task.yield()
        }
        XCTFail("The current preview was not published")
    }

    func testChangingSelectionCancelsThePriorLoad() async {
        let started = expectation(description: "preview load started")
        let cancelled = expectation(description: "preview load cancelled")
        let loader = FilePreviewLoader(loader: { _ in
            await withTaskCancellationHandler(operation: {
                started.fulfill()
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                return .unsupported
            }, onCancel: {
                cancelled.fulfill()
            })
        })

        loader.select(URL(fileURLWithPath: "/tmp/slow.txt"))
        await fulfillment(of: [started], timeout: 1)
        loader.select(nil)
        await fulfillment(of: [cancelled], timeout: 1)

        guard case .none = loader.preview else {
            return XCTFail("Clearing selection must synchronously clear the preview")
        }
    }

    func testSelectingTheSamePathAgainReloadsOverwrittenContent() async throws {
        let made = try fixture(named: "selected.txt", data: Data("before".utf8))
        defer { try? FileManager.default.removeItem(at: made.directory) }
        let loader = FilePreviewLoader()

        loader.select(made.file)
        let loadedBefore = await waitForText("before", from: loader)
        XCTAssertTrue(loadedBefore)

        try Data("after".utf8).write(to: made.file, options: .atomic)
        loader.select(made.file)

        let loadedAfter = await waitForText("after", from: loader)
        XCTAssertTrue(loadedAfter)
    }
}
