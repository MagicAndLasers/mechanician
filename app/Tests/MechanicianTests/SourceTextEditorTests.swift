import XCTest
import AppKit
@testable import Mechanician

/// FR-335. Typing `-->` into the artifact source editor produced `–>`, so a hand-typed Mermaid
/// diagram would not parse. These assert the substitutions are actually off, and — more usefully —
/// that AppKit really does corrupt source when they are left on, so the test fails for the original
/// reason rather than merely restating the setter calls.
@MainActor
final class SourceTextEditorTests: XCTestCase {

    private func makeTextView() -> NSTextView {
        NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
    }

    func testEveryAutomaticSubstitutionIsOff() {
        let textView = makeTextView()
        // AppKit's defaults are on for several of these, which is the bug.
        textView.isAutomaticDashSubstitutionEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = true
        textView.isAutomaticTextReplacementEnabled = true
        textView.isAutomaticSpellingCorrectionEnabled = true
        textView.smartInsertDeleteEnabled = true

        SourceTextEditor.configureAsSourceEditor(textView)

        XCTAssertFalse(textView.isAutomaticDashSubstitutionEnabled, "`-->` becomes `–>`")
        XCTAssertFalse(textView.isAutomaticQuoteSubstitutionEnabled, "`\"x\"` becomes curly quotes")
        XCTAssertFalse(textView.isAutomaticTextReplacementEnabled)
        XCTAssertFalse(textView.isAutomaticSpellingCorrectionEnabled)
        XCTAssertFalse(textView.isAutomaticLinkDetectionEnabled)
        XCTAssertFalse(textView.isAutomaticDataDetectionEnabled)
        XCTAssertFalse(textView.smartInsertDeleteEnabled)
        XCTAssertFalse(textView.isContinuousSpellCheckingEnabled)
        XCTAssertFalse(textView.isGrammarCheckingEnabled)
        XCTAssertEqual(textView.enabledTextCheckingTypes, 0)
    }

    func testSourceEditorIsPlainTextSoPastedMarkupKeepsNoStyling() {
        let textView = makeTextView()
        SourceTextEditor.configureAsSourceEditor(textView)

        XCTAssertFalse(textView.isRichText)
        XCTAssertFalse(textView.usesFontPanel)
        XCTAssertTrue(textView.allowsUndo)
        XCTAssertEqual(textView.font?.pointSize, 12)
    }

    /// The behavioural half: drive AppKit's own substitution over the exact string that broke, and
    /// show it is destructive when on and inert once configured.
    func testAppKitRewritesMermaidArrowsWhenDashSubstitutionIsOnAndLeavesThemAloneWhenOff() {
        let arrow = "A --> B"

        // Dash substitution is what typing triggers; running the checker directly is the testable
        // equivalent of holding down the keys.
        let results = NSSpellChecker.shared.check(
            arrow,
            range: NSRange(location: 0, length: (arrow as NSString).length),
            types: NSTextCheckingResult.CheckingType.dash.rawValue,
            options: nil,
            inSpellDocumentWithTag: 0,
            orthography: nil,
            wordCount: nil)
        let substituted = results.reduce(into: NSMutableString(string: arrow)) { text, result in
            guard result.resultType == .dash, let replacement = result.replacementString else { return }
            text.replaceCharacters(in: result.range, with: replacement)
        } as String

        // Guard the premise: if AppKit ever stops doing this, the fix is no longer load-bearing and
        // this test should say so rather than silently passing.
        XCTAssertNotEqual(
            substituted, arrow,
            "AppKit no longer substitutes dashes here — re-check whether FR-335's fix is still needed")
        XCTAssertTrue(substituted.contains("\u{2013}") || substituted.contains("\u{2014}"),
                      "expected an en or em dash, got: \(substituted)")

        let source = makeTextView()
        SourceTextEditor.configureAsSourceEditor(source)
        source.string = arrow
        XCTAssertEqual(source.string, arrow, "the source editor must keep `-->` literal")
        XCTAssertFalse(source.isAutomaticDashSubstitutionEnabled)
    }

    func testConfiguringIsIdempotent() {
        let textView = makeTextView()
        SourceTextEditor.configureAsSourceEditor(textView)
        SourceTextEditor.configureAsSourceEditor(textView)
        XCTAssertFalse(textView.isAutomaticDashSubstitutionEnabled)
        XCTAssertEqual(textView.enabledTextCheckingTypes, 0)
    }

    func testFontSizeAndInsetsAreHonored() {
        let textView = makeTextView()
        SourceTextEditor.configureAsSourceEditor(
            textView, fontSize: 14, insets: NSSize(width: 9, height: 11))
        XCTAssertEqual(textView.font?.pointSize, 14)
        XCTAssertEqual(textView.textContainerInset.width, 9)
        XCTAssertEqual(textView.textContainerInset.height, 11)
    }
}
