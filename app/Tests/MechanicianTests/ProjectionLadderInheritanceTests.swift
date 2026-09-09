import Foundation
import XCTest
@testable import Mechanician

/// A structural guard on the projection migration ladder.
///
/// The cap that shipped in 0.26.44 put `DELETE FROM entry_fts` inside
/// `createLatestAdditiveObjects()`, which every rung calls. That was correct for v15, where the
/// per-entry cap made the old index obsolete, and silently wrong afterwards: it meant any future
/// schema bump would re-tokenize the whole transcript corpus whether or not the change had anything
/// to do with the index. On a 1.3 GB index that is minutes of work for nothing, and it is the exact
/// cost the ladder's own doc comment warns about.
///
/// Behaviour is covered by `MemoryProjectionSchemaTests`, which asserts pre-cap indexes really are
/// discarded on the v5, v8 and v9 rungs. What those cannot cover is the *future* rung nobody has
/// written yet, because the current schema version is the newest one. This asserts the shape
/// instead: the discard has to be asked for.
final class ProjectionLadderInheritanceTests: XCTestCase {

    private func projectionStoreSource() throws -> String {
        // Tests live at app/Tests/MechanicianTests/; the source at app/Sources/Mechanician/.
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // MechanicianTests
            .deletingLastPathComponent()      // Tests
            .deletingLastPathComponent()      // app
            .appendingPathComponent("Sources/Mechanician/ProjectionStore.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func body(of function: String, in source: String) throws -> String {
        guard let start = source.range(of: "private func \(function)() -> Bool {") else {
            throw XCTSkip("\(function) has been renamed; update this guard rather than deleting it")
        }
        // Brace-match from the opening brace so a nested closure cannot end the body early.
        var depth = 0
        var index = source.index(before: start.upperBound)
        let open = index
        while index < source.endIndex {
            if source[index] == "{" { depth += 1 }
            if source[index] == "}" {
                depth -= 1
                if depth == 0 { return String(source[open...index]) }
            }
            index = source.index(after: index)
        }
        XCTFail("\(function) has no balanced body")
        return ""
    }

    /// The creator creates. It must not also throw away the most expensive thing in the cache.
    func testAdditiveObjectCreationDoesNotDiscardTheConversationIndex() throws {
        let source = try projectionStoreSource()
        let creator = try body(of: "createLatestAdditiveObjects", in: source)
        XCTAssertFalse(
            creator.contains("entry_fts"),
            """
            createLatestAdditiveObjects() must not touch entry_fts. Every rung calls it, so anything \
            it does is inherited by every future schema bump. A rung that wants the pre-cap index \
            discarded calls discardPreCapConversationIndex() explicitly.
            """)
    }

    /// The discard exists, is separate, and every rung that needs it asks by name.
    ///
    /// This counted call sites once: exactly one creator that did not discard, the fresh-create
    /// path. That held only while every rung in the ladder arrived from below v15. The v16 rung is
    /// the first that must NOT discard — dropping a retired table invalidates no indexed row — so
    /// counting stopped being able to say the thing. It now asserts the rule instead: a rung's own
    /// version decides, and both directions are wrong in expensive, silent ways.
    func testThePreCapDiscardIsItsOwnStepAndIsAskedForExplicitly() throws {
        let source = try projectionStoreSource()
        let discard = try body(of: "discardPreCapConversationIndex", in: source)
        XCTAssertTrue(
            discard.contains("DELETE FROM entry_fts"),
            "the discard step must actually discard, or every rung silently keeps a stale index")

        var examined = 0
        for rung in ladderRungs(in: source) {
            examined += 1
            let discards = rung.body.contains("discardPreCapConversationIndex()")
            if rung.fromVersion == 0 {
                XCTAssertFalse(
                    discards,
                    "the fresh-create path has no index to discard")
            } else if rung.fromVersion < 15 {
                XCTAssertTrue(
                    discards,
                    """
                    the rung from v\(rung.fromVersion) arrives with a PRE-CAP index and must \
                    discard it; without this its stale rows survive the stamp
                    """)
            } else {
                XCTAssertFalse(
                    discards,
                    """
                    the rung from v\(rung.fromVersion) arrives with a post-cap index. Discarding \
                    it re-tokenizes the whole transcript corpus for a change that has nothing to \
                    do with the index, which is the exact cost this separation exists to prevent.
                    """)
            }
        }
        XCTAssertGreaterThan(examined, 8, "the ladder rungs were not found; the parse has drifted")
    }

    /// Every `if version == N` (or `== N || == M`) block in `verifySchema`, with its body.
    ///
    /// Parsed rather than listed, so a rung added without a test is still examined. `fromVersion`
    /// is the LOWEST version the block accepts, which is the one that decides whether the index
    /// arriving is pre-cap.
    private func ladderRungs(in source: String) -> [(fromVersion: Int, body: String)] {
        var rungs: [(Int, String)] = []
        var search = source.startIndex
        while let marker = source.range(of: "if version == ", range: search..<source.endIndex) {
            search = marker.upperBound
            guard let brace = source.range(of: "{", range: marker.upperBound..<source.endIndex)
            else { break }
            let condition = String(source[marker.upperBound..<brace.lowerBound])
            let versions = condition
                .components(separatedBy: CharacterSet.decimalDigits.inverted)
                .compactMap(Int.init)
            guard let lowest = versions.min() else { continue }
            var depth = 0
            var index = brace.lowerBound
            var end = brace.upperBound
            while index < source.endIndex {
                if source[index] == "{" { depth += 1 }
                if source[index] == "}" {
                    depth -= 1
                    if depth == 0 { end = source.index(after: index); break }
                }
                index = source.index(after: index)
            }
            rungs.append((lowest, String(source[brace.lowerBound..<end])))
        }
        return rungs
    }
}
