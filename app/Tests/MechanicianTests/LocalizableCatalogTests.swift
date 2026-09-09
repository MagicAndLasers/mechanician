import XCTest
@testable import Mechanician

/// The string catalogue, checked as data.
///
/// Every user-facing plural in the app now resolves through this file rather than through a
/// `count == 1 ? …` ternary, which means the singular form exists *only* here. That is the right
/// place for it — English needs two forms and several languages need up to six — but it moves the
/// failure: a missing `one` variation no longer fails to compile, it ships an app that says
/// "Undo Delete 1 Conversations".
///
/// These assertions cannot run through `String(localized:)`. That goes to `Bundle.main`, which
/// under `xctest` is the test runner and carries no catalogue, so every lookup falls back to the
/// key. The catalogue is therefore read directly from source.
final class LocalizableCatalogTests: XCTestCase {
    private struct Catalog: Decodable {
        struct Entry: Decodable {
            struct Localization: Decodable {
                struct Variations: Decodable {
                    struct Unit: Decodable {
                        struct StringUnit: Decodable { let value: String }
                        let stringUnit: StringUnit
                    }
                    let plural: [String: Unit]?
                }
                let variations: Variations?
            }
            let comment: String?
            let localizations: [String: Localization]?
        }
        let sourceLanguage: String
        let strings: [String: Entry]
    }

    /// Walks up from this file to the package root, so the test does not depend on the working
    /// directory the runner happens to use.
    private func catalogURL() throws -> URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { url.deleteLastPathComponent() }
        let catalog = url.appendingPathComponent("Resources/Localizable.xcstrings")
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: catalog.path),
            "catalogue not found at \(catalog.path)")
        return catalog
    }

    private func loadCatalog() throws -> Catalog {
        try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: try catalogURL()))
    }

    /// The plural entries, and the singular each must produce. These are the strings AppKit
    /// composes "Undo " in front of, so a wrong one is visible in the Edit menu.
    private static let expectedPlurals: [String: (one: String, other: String)] = [
        "Delete %lld Conversations": ("Delete Conversation", "Delete %lld Conversations"),
        "Delete %lld Artifacts": ("Delete Artifact", "Delete %lld Artifacts"),
        "Move %lld Conversations": ("Move Conversation", "Move %lld Conversations"),
        "Move %lld Artifacts": ("Move Artifact", "Move %lld Artifacts"),
        "Pin %lld Conversations": ("Pin Conversation", "Pin %lld Conversations"),
        "Unpin %lld Conversations": ("Unpin Conversation", "Unpin %lld Conversations"),
    ]

    func testEveryDeclaredPluralHasBothEnglishForms() throws {
        let catalog = try loadCatalog()
        XCTAssertEqual(catalog.sourceLanguage, "en")
        for (key, expected) in Self.expectedPlurals {
            guard let plural = catalog.strings[key]?
                .localizations?["en"]?.variations?.plural else {
                XCTFail("\(key) has no English plural variations")
                continue
            }
            XCTAssertEqual(
                plural["one"]?.stringUnit.value, expected.one,
                "\(key) singular — this is the form that only exists in the catalogue")
            XCTAssertEqual(plural["other"]?.stringUnit.value, expected.other, "\(key) plural")
        }
    }

    /// A plural whose `other` form drops the count reads as a bare noun for every number but one.
    /// A specifier that differs between forms is worse: it crashes the formatter.
    func testPluralFormsKeepTheirCountSpecifier() throws {
        let catalog = try loadCatalog()
        for (key, entry) in catalog.strings {
            guard let plural = entry.localizations?["en"]?.variations?.plural else { continue }
            XCTAssertTrue(key.contains("%lld"), "\(key) is a plural but its key takes no count")
            XCTAssertTrue(
                plural["other"]?.stringUnit.value.contains("%lld") ?? false,
                "\(key) 'other' form must keep the count")
            XCTAssertFalse(
                plural["one"]?.stringUnit.value.contains("%") ?? true,
                "\(key) 'one' form should read as a bare singular, with no number in it")
        }
    }

    /// Every entry carries a comment. A translator sees the key and the comment and nothing else,
    /// and several of these keys are ambiguous without one — "New Conversation" is a verb phrase
    /// here, not a label for a conversation that is new.
    func testEveryEntryIsCommentedForATranslator() throws {
        for (key, entry) in try loadCatalog().strings {
            XCTAssertFalse(
                (entry.comment ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                "\(key) has no comment")
        }
    }
}
