import AppKit
import XCTest
@testable import Mechanician

@MainActor
final class IncrementalMarkdownRenderingTests: XCTestCase {
    func testAppendPrefixesMatchCanonicalRendererAcrossMarkdownShapes() {
        let fixtures: [(name: String, chunks: [String])] = [
            (
                "paragraphs and blank lines",
                [
                    "First", " paragraph", ".", "\n", "\n",
                    "Second", " paragraph", " spans two", "\nlines.",
                ]
            ),
            (
                "fenced code",
                [
                    "Intro paragraph.\n\n", "```s", "wift\n", "let value = ", "1\n",
                    "print(value)\n", "```", "\n\nAfter the fence.",
                ]
            ),
            (
                "table",
                [
                    "| Name", " | Value |\n", "|:---", "|---:|\n", "| café | ",
                    "**yes** |\n", "| 東京 | `2` |", "\n\nFollowing paragraph.",
                ]
            ),
            (
                "lists",
                [
                    "Lead paragraph.\n\n", "- first", " item\n", "* second item\n",
                    "1. numbered", " item\n", "2) final item",
                ]
            ),
            (
                "inline syntax",
                [
                    "This is **bo", "ld** and *em", "phasized* with `co", "de`, ",
                    "~~removed~~, and [a li", "nk](https://example.com).",
                ]
            ),
            (
                "Unicode",
                [
                    "👩🏽‍💻", " writes café", " and e\u{301}", " in 東京", ".\n\n",
                    "Flags 🇯🇵 and family 👨‍👩‍👧‍👦 remain intact.",
                ]
            ),
        ]

        for fixture in fixtures {
            var document = NativeMarkdownIncrementalDocument()
            let installed = NSMutableAttributedString()
            var source = ""
            var previousStableRenderedLength = 0

            for (index, chunk) in fixture.chunks.enumerated() {
                source.append(chunk)
                guard let update = document.update(source: source, scale: 1) else {
                    XCTFail("\(fixture.name) prefix \(index) was an append but returned no update")
                    break
                }

                XCTAssertGreaterThanOrEqual(
                    update.replacementStart,
                    0,
                    "\(fixture.name) prefix \(index) returned a negative replacement start"
                )
                XCTAssertLessThanOrEqual(
                    update.replacementStart,
                    installed.length,
                    "\(fixture.name) prefix \(index) returned a replacement start past the document"
                )
                installed.replaceCharacters(
                    in: NSRange(
                        location: update.replacementStart,
                        length: installed.length - update.replacementStart
                    ),
                    with: update.replacement
                )

                let canonical = NativeMarkdownRenderer.render(source, scale: 1)
                XCTAssertEqual(
                    semanticSignature(of: installed),
                    semanticSignature(of: canonical),
                    "\(fixture.name) prefix \(index) diverged from a canonical render"
                )
                XCTAssertGreaterThanOrEqual(
                    update.stableRenderedLength,
                    previousStableRenderedLength,
                    "\(fixture.name) prefix \(index) moved the stable boundary backwards"
                )
                XCTAssertLessThanOrEqual(
                    update.stableRenderedLength,
                    installed.length,
                    "\(fixture.name) prefix \(index) placed the stable boundary past the render"
                )
                previousStableRenderedLength = update.stableRenderedLength
            }
        }
    }

    func testCompletedParagraphMovesLaterReplacementPastStablePrefix() {
        var document = NativeMarkdownIncrementalDocument()
        let installed = NSMutableAttributedString()
        let stableSource = "A complete first paragraph.\n\n"

        guard let first = document.update(source: stableSource, scale: 1) else {
            return XCTFail("the initial append should produce an update")
        }
        installed.replaceCharacters(
            in: NSRange(location: 0, length: 0),
            with: first.replacement
        )

        let appendedSource = stableSource + "A still-streaming second paragraph"
        guard let second = document.update(source: appendedSource, scale: 1) else {
            return XCTFail("the second append should produce an update")
        }
        installed.replaceCharacters(
            in: NSRange(
                location: second.replacementStart,
                length: installed.length - second.replacementStart
            ),
            with: second.replacement
        )
        XCTAssertGreaterThan(second.stableRenderedLength, first.stableRenderedLength)

        let laterSource = appendedSource + " grows"
        guard let third = document.update(source: laterSource, scale: 1) else {
            return XCTFail("the third append should produce an update")
        }

        XCTAssertGreaterThan(
            third.replacementStart,
            0,
            "a completed paragraph should not be rendered again on the next append"
        )
        XCTAssertGreaterThanOrEqual(third.stableRenderedLength, second.stableRenderedLength)
        installed.replaceCharacters(
            in: NSRange(
                location: third.replacementStart,
                length: installed.length - third.replacementStart
            ),
            with: third.replacement
        )
        XCTAssertEqual(
            semanticSignature(of: installed),
            semanticSignature(of: NativeMarkdownRenderer.render(laterSource, scale: 1))
        )
    }

    func testNonPrefixSourceChangeReturnsNil() {
        var document = NativeMarkdownIncrementalDocument()
        XCTAssertNotNil(document.update(source: "Original paragraph.", scale: 1))

        XCTAssertNil(
            document.update(source: "Replaced paragraph.", scale: 1),
            "incremental rendering must reject edits to already-seen source"
        )
    }
}

private struct MarkdownDocumentSignature: Equatable {
    let string: String
    let runs: [MarkdownAttributeRunSignature]
}

private struct MarkdownAttributeRunSignature: Equatable {
    let range: NSRange
    let keys: [String]
    let font: MarkdownFontSignature?
    let foregroundColor: MarkdownColorSignature?
    let backgroundColor: MarkdownColorSignature?
    let link: String?
    let inlinePresentationIntent: UInt?
    let paragraph: MarkdownParagraphSignature?
    let strikethroughStyle: Int?
    let codeSource: String?
}

private struct MarkdownFontSignature: Equatable {
    let name: String
    let pointSize: CGFloat
    let descriptorTraits: String
    let managerTraits: String
}

private struct MarkdownColorSignature: Equatable {
    let colorSpace: String
    let red: CGFloat
    let green: CGFloat
    let blue: CGFloat
    let alpha: CGFloat
}

private struct MarkdownParagraphSignature: Equatable {
    let alignment: Int
    let baseWritingDirection: Int
    let lineBreakMode: Int
    let lineSpacing: CGFloat
    let paragraphSpacing: CGFloat
    let paragraphSpacingBefore: CGFloat
    let firstLineHeadIndent: CGFloat
    let headIndent: CGFloat
    let tailIndent: CGFloat
    let minimumLineHeight: CGFloat
    let maximumLineHeight: CGFloat
    let lineHeightMultiple: CGFloat
    let textBlocks: [MarkdownTextBlockSignature]
}

private struct MarkdownTextBlockSignature: Equatable {
    let type: String
    let backgroundColor: MarkdownColorSignature?
}

private func semanticSignature(of attributed: NSAttributedString) -> MarkdownDocumentSignature {
    var runs: [MarkdownAttributeRunSignature] = []
    let whole = NSRange(location: 0, length: attributed.length)
    attributed.enumerateAttributes(in: whole, options: []) { attributes, range, _ in
        let font = (attributes[.font] as? NSFont).map {
            MarkdownFontSignature(
                name: $0.fontName,
                pointSize: $0.pointSize,
                descriptorTraits: String(describing: $0.fontDescriptor.symbolicTraits.rawValue),
                managerTraits: String(describing: NSFontManager.shared.traits(of: $0).rawValue)
            )
        }
        let paragraph = (attributes[.paragraphStyle] as? NSParagraphStyle).map {
            MarkdownParagraphSignature(
                alignment: $0.alignment.rawValue,
                baseWritingDirection: $0.baseWritingDirection.rawValue,
                lineBreakMode: Int($0.lineBreakMode.rawValue),
                lineSpacing: $0.lineSpacing,
                paragraphSpacing: $0.paragraphSpacing,
                paragraphSpacingBefore: $0.paragraphSpacingBefore,
                firstLineHeadIndent: $0.firstLineHeadIndent,
                headIndent: $0.headIndent,
                tailIndent: $0.tailIndent,
                minimumLineHeight: $0.minimumLineHeight,
                maximumLineHeight: $0.maximumLineHeight,
                lineHeightMultiple: $0.lineHeightMultiple,
                textBlocks: $0.textBlocks.map {
                    MarkdownTextBlockSignature(
                        type: String(reflecting: type(of: $0)),
                        backgroundColor: semanticColor($0.backgroundColor)
                    )
                }
            )
        }
        runs.append(MarkdownAttributeRunSignature(
            range: range,
            keys: attributes.keys.map(\.rawValue).sorted(),
            font: font,
            foregroundColor: semanticColor(attributes[.foregroundColor] as? NSColor),
            backgroundColor: semanticColor(attributes[.backgroundColor] as? NSColor),
            link: semanticLink(attributes[.link]),
            inlinePresentationIntent: (attributes[.inlinePresentationIntent] as? NSNumber)?.uintValue,
            paragraph: paragraph,
            strikethroughStyle: (attributes[.strikethroughStyle] as? NSNumber)?.intValue,
            codeSource: attributes[.mechanicianCodeSource] as? String
        ))
    }
    return MarkdownDocumentSignature(string: attributed.string, runs: runs)
}

private func semanticColor(_ color: NSColor?) -> MarkdownColorSignature? {
    guard let converted = color?.usingColorSpace(.deviceRGB) else { return nil }
    return MarkdownColorSignature(
        colorSpace: String(describing: converted.colorSpace.colorSpaceModel),
        red: converted.redComponent,
        green: converted.greenComponent,
        blue: converted.blueComponent,
        alpha: converted.alphaComponent
    )
}

private func semanticLink(_ value: Any?) -> String? {
    if let url = value as? URL { return url.absoluteString }
    if let url = value as? NSURL { return url.absoluteString }
    if let string = value as? String { return string }
    return value.map { String(describing: $0) }
}
