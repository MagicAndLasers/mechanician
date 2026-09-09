import AppKit
import XCTest
@testable import Mechanician

@MainActor
final class TranscriptLinkHandlerTests: XCTestCase {
    private func fixture(named name: String, data: Data) throws -> (directory: URL, file: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcript-link-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(name)
        try data.write(to: file)
        return (directory, file)
    }

    func testRelativeAbsoluteAndSourceLocationLinksResolveToTheSameFile() throws {
        let fixture = try fixture(named: "example file.swift", data: Data("let x = 1".utf8))
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let relative = URL(string: "example%20file.swift")!
        XCTAssertEqual(
            TranscriptLinkHandler.localFileURL(
                from: relative,
                relativeTo: fixture.directory.path),
            fixture.file.standardizedFileURL)

        let absoluteWithLocation = URL(string: "\(fixture.file.path):42:7")!
        XCTAssertEqual(
            TranscriptLinkHandler.localFileURL(
                from: absoluteWithLocation,
                relativeTo: ""),
            fixture.file.standardizedFileURL)
    }

    func testTextLinkMenuOffersBothOpenRoutesAndLocationActions() throws {
        let fixture = try fixture(named: "readme.md", data: Data("# Read me".utf8))
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let menu = try XCTUnwrap(TranscriptLinkHandler.contextMenu(
            for: fixture.file,
            relativeTo: ""))
        XCTAssertEqual(
            menu.items.filter { !$0.isSeparatorItem }.map(\.title),
            ["Preview in Mechanician", "Open in Default App", "Reveal in Finder", "Copy Path"])
    }

    func testBinaryLinkMenuOffersBothRoutesWithoutReadingTheFile() throws {
        let fixture = try fixture(
            named: "archive.bin",
            data: Data([0x00, 0x01, 0x02, 0x03]))
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let menu = try XCTUnwrap(TranscriptLinkHandler.contextMenu(
            for: fixture.file,
            relativeTo: ""))
        XCTAssertEqual(
            menu.items.filter { !$0.isSeparatorItem }.map(\.title),
            ["Preview in Mechanician", "Open in Default App", "Reveal in Finder", "Copy Path"])
    }

    func testSpecialFileDoesNotGetAPreviewMenu() {
        XCTAssertNil(TranscriptLinkHandler.contextMenu(
            for: URL(fileURLWithPath: "/dev/null"),
            relativeTo: ""))
        XCTAssertThrowsError(try TranscriptFilePreview.text(
            at: URL(fileURLWithPath: "/dev/null"))) { error in
            guard case TranscriptFilePreviewError.notRegularFile = error else {
                return XCTFail("expected notRegularFile, got \(error)")
            }
        }
    }

    func testSymlinksFollowOnlyRegularFileTargets() throws {
        let fixture = try fixture(named: "target.txt", data: Data("linked text".utf8))
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let regularLink = fixture.directory.appendingPathComponent("regular-link.txt")
        try FileManager.default.createSymbolicLink(
            at: regularLink,
            withDestinationURL: fixture.file)

        XCTAssertNotNil(TranscriptLinkHandler.contextMenu(
            for: regularLink,
            relativeTo: ""))
        XCTAssertEqual(try TranscriptFilePreview.text(at: regularLink), "linked text")

        let specialLink = fixture.directory.appendingPathComponent("special-link")
        try FileManager.default.createSymbolicLink(
            at: specialLink,
            withDestinationURL: URL(fileURLWithPath: "/dev/null"))
        XCTAssertNil(TranscriptLinkHandler.contextMenu(
            for: specialLink,
            relativeTo: ""))
        XCTAssertThrowsError(try TranscriptFilePreview.text(at: specialLink)) { error in
            guard case TranscriptFilePreviewError.notRegularFile = error else {
                return XCTFail("expected notRegularFile, got \(error)")
            }
        }
    }

    func testBinaryOrdinaryClickUsesInjectedDefaultApplicationOpener() throws {
        let fixture = try fixture(
            named: "image.bin",
            data: Data([0x00, 0x01, 0x02, 0x03]))
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        var opened: URL?
        let actions = TranscriptFileActionEnvironment(
            openInDefaultApplication: {
                opened = $0
                return true
            },
            revealInFinder: { _ in XCTFail("ordinary click revealed in Finder") },
            copyPath: { _ in XCTFail("ordinary click copied a path") })

        XCTAssertTrue(TranscriptLinkHandler.handleLocal(
            fixture.file,
            relativeTo: "",
            actions: actions))
        XCTAssertEqual(opened, fixture.file)
    }

    func testPreviewReadIsBoundedAndRejectsNulBearingData() throws {
        let oversized = try fixture(
            named: "large.txt",
            data: Data(repeating: 0x61, count: TranscriptFilePreview.maxPreviewBytes + 1))
        defer { try? FileManager.default.removeItem(at: oversized.directory) }
        XCTAssertThrowsError(try TranscriptFilePreview.text(at: oversized.file)) { error in
            guard case TranscriptFilePreviewError.tooLarge = error else {
                return XCTFail("expected tooLarge, got \(error)")
            }
        }

        let binary = try fixture(
            named: "nul.txt",
            data: Data([0x61, 0x00, 0x62]))
        defer { try? FileManager.default.removeItem(at: binary.directory) }
        XCTAssertThrowsError(try TranscriptFilePreview.text(at: binary.file)) { error in
            guard case TranscriptFilePreviewError.notUTF8 = error else {
                return XCTFail("expected notUTF8, got \(error)")
            }
        }
    }

    func testNativeTextViewDelegateReplacesOnlyALocalLinksContextMenu() throws {
        _ = NSApplication.shared
        let fixture = try fixture(named: "linked.txt", data: Data("linked".utf8))
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let cell = NativeAssistantCell(frame: NSRect(x: 0, y: 0, width: 500, height: 200))
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
        textView.textStorage?.setAttributedString(NSAttributedString(
            string: "linked",
            attributes: [.link: fixture.file]))
        let fallback = NSMenu()
        fallback.addItem(withTitle: "Fallback", action: nil, keyEquivalent: "")
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1))

        let localMenu = try XCTUnwrap(cell.textView(
            textView,
            menu: fallback,
            for: event,
            at: 2))
        XCTAssertEqual(
            localMenu.items.filter { !$0.isSeparatorItem }.map(\.title),
            ["Preview in Mechanician", "Open in Default App", "Reveal in Finder", "Copy Path"])

        let untouched = cell.textView(
            textView,
            menu: fallback,
            for: event,
            at: textView.string.count)
        XCTAssertTrue(untouched === fallback)
    }
}
