import AppKit
import XCTest
@testable import Mechanician

/// Sharing a file from the browser, the way a Mac user expects to.
final class FileBrowserShareTests: XCTestCase {

    private func source() throws -> String {
        try String(
            contentsOfFile: #filePath.replacingOccurrences(
                of: "Tests/MechanicianTests/FileBrowserShareTests.swift",
                with: "Sources/Mechanician/FileBrowserPanelView.swift"),
            encoding: .utf8)
    }

    /// The system picker, not a list of services we invent: it carries everything this Mac actually
    /// has, including whatever the person added, and stays right as the OS changes.
    func testShareUsesTheSystemPicker() throws {
        let view = try source()
        XCTAssertTrue(view.contains("NSSharingServicePicker(items: targets as [Any])"))
        XCTAssertTrue(
            view.contains("preferredEdge: .maxY"),
            "shown from the row, so the popover belongs to the file it is about")
    }

    /// It sits beside Reveal in Finder, which is where the same command lives in Finder itself.
    func testShareIsOfferedBesideReveal() throws {
        let view = try source()
        let reveal = try XCTUnwrap(view.range(of: "#selector(miReveal(_:)), targets)"))
        let share = try XCTUnwrap(view.range(of: "#selector(miShare(_:)), targets)"))
        XCTAssertTrue(reveal.upperBound < share.lowerBound)
        let between = String(view[reveal.upperBound..<share.lowerBound])
        XCTAssertFalse(
            between.contains("menu.addItem(.separator())"),
            "in the same group, not stranded in another")
    }

    /// Multi-select shares every selected file, and says how many, like the rest of this menu.
    func testItSharesTheWholeSelection() throws {
        let view = try source()
        XCTAssertTrue(
            view.contains("add(isBulk ? \"Share \\(targets.count) Items…\" : \"Share…\""),
            "the same bulk phrasing Reveal, Copy and Trash already use")
    }

    /// An empty selection has nothing to share, and a picker over nothing is a beachball.
    func testItRefusesAnEmptySelection() throws {
        let view = try source()
        let start = try XCTUnwrap(view.range(of: "@objc private func miShare(_ s: NSMenuItem)"))
        let body = String(view[start.lowerBound...].prefix(500))
        XCTAssertTrue(body.contains("guard !targets.isEmpty"))
    }
}
