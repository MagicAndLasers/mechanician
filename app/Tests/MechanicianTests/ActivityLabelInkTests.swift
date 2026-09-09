import AppKit
import XCTest
@testable import Mechanician

/// Activity spans deliberately use one white label treatment. The phase or tool remains encoded by
/// the fill; adjacent bars must not alternate between black and white text as their ray changes.
@MainActor
final class ActivityLabelInkTests: XCTestCase {
    private let light = NSAppearance(named: .aqua)!
    private let dark = NSAppearance(named: .darkAqua)!

    func testEveryLabeledPhaseUsesWhiteInkInBothAppearances() {
        let phases: [AgentActivityPhase] = [.model, .tool, .waiting, .compacting]
        for appearance in [light, dark] {
            for phase in phases {
                XCTAssertEqual(
                    appKitAgentActivitySpanLabelColor(
                        phase,
                        background: .nElevated,
                        appearance: appearance),
                    .white,
                    "\(phase) in \(appearance.name.rawValue)")
            }
        }
    }

    func testEveryToolLabelUsesWhiteInkInBothAppearances() {
        let tools = ["git", "export", "Bash", "Read", "WebSearch", "Edit", "Glob", "other"]
        for appearance in [light, dark] {
            for tool in tools {
                XCTAssertEqual(
                    appKitAgentActivitySpanLabelColor(
                        .tool,
                        tool: tool,
                        background: .nElevated,
                        appearance: appearance),
                    .white,
                    "\(tool) in \(appearance.name.rawValue)")
            }
        }
    }

    /// PLAIN WHITE, WITH NOTHING BEHIND IT. The dark outline was added so glyphs would separate
    /// from every possible ray colour, and on screen it reads as a black fringe around each letter
    /// that makes small text harder to read — the opposite of what a contrast aid is for. David
    /// reported it and has asked for plain white text repeatedly.
    func testSpanLabelsHaveNothingDrawnBehindTheLetters() {
        XCTAssertEqual(
            appKitAgentActivitySpanLabelStrokeWidth(), 0,
            "a non-zero stroke paints an outline around every glyph")
        XCTAssertEqual(
            appKitAgentActivitySpanLabelOutlineColor().alphaComponent, 0,
            "and nothing may be painted even if a width came back")
    }

    func testSpanLabelsKeepAReadableWhiteCoreAtTraceScale() {
        let font = appKitAgentActivitySpanLabelFont()
        XCTAssertEqual(font.pointSize, 9)
        XCTAssertTrue(
            font.fontDescriptor.symbolicTraits.contains(.bold),
            "moving span labels need semibold glyph area; medium 8-point ink reads as a grey fringe")
        // Weight is what carries these now: semibold at 9 points, on the fill, with nothing behind
        // the letters. The answer to a fill too quiet for white is a better fill.
        XCTAssertEqual(appKitAgentActivitySpanLabelOutlineColor().alphaComponent, 0)
    }
}
