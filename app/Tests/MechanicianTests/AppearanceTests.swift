import AppKit
import SwiftUI
import XCTest
@testable import Mechanician

final class AppearanceTests: XCTestCase {
    func testPersistedAppearancePolicyNormalizesAndMapsEveryValue() {
        XCTAssertEqual(
            MechanicianAppearancePreference(storedValue: nil),
            .system)
        XCTAssertEqual(
            MechanicianAppearancePreference(storedValue: "unexpected-old-value"),
            .system)
        XCTAssertEqual(
            MechanicianAppearancePreference(storedValue: "light"),
            .light)
        XCTAssertEqual(
            MechanicianAppearancePreference(storedValue: "dark"),
            .dark)

        XCTAssertNil(appAppearance(for: "system"))
        XCTAssertEqual(appAppearance(for: "light")?.name, .aqua)
        XCTAssertEqual(appAppearance(for: "dark")?.name, .darkAqua)
    }

    /// The reported Light Mode corruption came from storing a dynamic color's `cgColor` while the
    /// Mac itself was dark. A layer has no dynamic-color semantics after assignment, so prove that
    /// the shared resolver follows the target view appearance instead of ambient process state.
    func testLayerColorResolutionUsesTheTargetAppearance() throws {
        let light = try XCTUnwrap(NSAppearance(named: .aqua))
        let dark = try XCTUnwrap(NSAppearance(named: .darkAqua))

        let lightSurface = try XCTUnwrap(
            NSColor(cgColor: NSColor.nSurface.mechanicianCGColor(in: light))?
                .usingColorSpace(.sRGB))
        let darkSurface = try XCTUnwrap(
            NSColor(cgColor: NSColor.nSurface.mechanicianCGColor(in: dark))?
                .usingColorSpace(.sRGB))

        XCTAssertEqual(lightSurface.redComponent, 1, accuracy: 0.005)
        XCTAssertEqual(lightSurface.greenComponent, 1, accuracy: 0.005)
        XCTAssertEqual(lightSurface.blueComponent, 1, accuracy: 0.005)
        XCTAssertEqual(darkSurface.redComponent, 0.137, accuracy: 0.005)
        XCTAssertEqual(darkSurface.greenComponent, 0.141, accuracy: 0.005)
        XCTAssertEqual(darkSurface.blueComponent, 0.153, accuracy: 0.005)
    }

    /// AppKit's built-in semantic colors can become concrete as soon as `withAlphaComponent` is
    /// called. On a dark-system Mac that froze dark control fills before a forced-Light view could
    /// resolve them. The helper therefore applies alpha only after resolving the target appearance.
    func testLayerAlphaIsAppliedAfterResolvingBuiltInSemanticColors() throws {
        let light = try XCTUnwrap(NSAppearance(named: .aqua))
        let dark = try XCTUnwrap(NSAppearance(named: .darkAqua))

        let lightFill = try XCTUnwrap(
            NSColor(cgColor: NSColor.controlBackgroundColor.mechanicianCGColor(
                in: light,
                alpha: 0.5))?.usingColorSpace(.sRGB))
        let darkFill = try XCTUnwrap(
            NSColor(cgColor: NSColor.controlBackgroundColor.mechanicianCGColor(
                in: dark,
                alpha: 0.5))?.usingColorSpace(.sRGB))

        XCTAssertEqual(lightFill.redComponent, 1, accuracy: 0.005)
        XCTAssertEqual(lightFill.greenComponent, 1, accuracy: 0.005)
        XCTAssertEqual(lightFill.blueComponent, 1, accuracy: 0.005)
        XCTAssertEqual(lightFill.alphaComponent, 0.5, accuracy: 0.005)
        XCTAssertLessThan(darkFill.redComponent, 0.2)
        XCTAssertEqual(darkFill.alphaComponent, 0.5, accuracy: 0.005)
    }

    func testSelectedConversationCopyRemainsLegibleOnNativeNeutralSelections() throws {
        let light = try XCTUnwrap(NSAppearance(named: .aqua))
        let dark = try XCTUnwrap(NSAppearance(named: .darkAqua))
        let lightSelection = NSColor(srgbRed: 0.78, green: 0.78, blue: 0.79, alpha: 1)
        let darkSelection = NSColor(srgbRed: 0.25, green: 0.25, blue: 0.27, alpha: 1)

        XCTAssertGreaterThanOrEqual(
            contrast(
                NSColor.nSelectedSecondaryText.mechanicianResolved(in: light),
                lightSelection),
            4.5)
        XCTAssertGreaterThanOrEqual(
            contrast(
                NSColor.nSelectedSecondaryText.mechanicianResolved(in: dark),
                darkSelection),
            4.5)
    }

    func testSmallSemanticTextPaletteMeetsContrastInBothAppearances() throws {
        let light = try XCTUnwrap(NSAppearance(named: .aqua))
        let dark = try XCTUnwrap(NSAppearance(named: .darkAqua))
        let tokens: [NSColor] = [
            .nInfoText, .nSuccessText, .nGoldText, .nWarningText, .nErrorText, .nPurpleText,
        ]
        for token in tokens {
            for appearance in [light, dark] {
                let ink = token.mechanicianResolved(in: appearance)
                let surface = NSColor.nSurface.mechanicianResolved(in: appearance)
                XCTAssertGreaterThanOrEqual(contrast(ink, surface), 4.5)
            }
        }

        XCTAssertGreaterThanOrEqual(
            contrast(
                NSColor.nChartMuted.mechanicianResolved(in: light),
                NSColor.nBg.mechanicianResolved(in: light)),
            4.5)
        XCTAssertGreaterThanOrEqual(
            contrast(
                NSColor.nChartMuted.mechanicianResolved(in: dark),
                NSColor.nBg.mechanicianResolved(in: dark)),
            4.5)
    }

    func testSolidActionFillCarriesWhiteInkInBothAppearances() throws {
        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
            XCTAssertGreaterThanOrEqual(
                contrast(
                    .white,
                    NSColor.nSolidActionFill.mechanicianResolved(in: appearance)),
                4.5,
                "solid white-on-blue action chrome must remain readable in \(appearanceName)")
        }
    }

    func testBrandActionFillCarriesWhiteInkAndBacksTheExistingPinAction() throws {
        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
            let fill = NSColor.nBrandActionFill.mechanicianResolved(in: appearance)
            let pinFill = NSColor.nPinnedFill.mechanicianResolved(in: appearance)

            XCTAssertGreaterThanOrEqual(
                contrast(.white, fill),
                4.5,
                "white brand-action ink must remain readable in \(appearanceName)")
            XCTAssertEqual(fill.redComponent, pinFill.redComponent, accuracy: 0.001)
            XCTAssertEqual(fill.greenComponent, pinFill.greenComponent, accuracy: 0.001)
            XCTAssertEqual(fill.blueComponent, pinFill.blueComponent, accuracy: 0.001)
        }
    }

    func testBrandActionHoverAndPressedStatesKeepWhiteInkReadable() throws {
        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
            let rest = NSColor.nBrandActionFill.mechanicianResolved(in: appearance)
            let hover = composite(.white, alpha: 0.10, over: rest)
            let pressed = composite(.black, alpha: 0.12, over: rest)

            for (state, fill) in [("rest", rest), ("hover", hover), ("pressed", pressed)] {
                XCTAssertGreaterThanOrEqual(
                    contrast(.white, fill),
                    4.5,
                    "white brand-action ink must remain readable at \(state) in \(appearanceName)")
            }
        }
    }

    func testProviderRecoveryWashStaysCoolSubtleAndReadable() throws {
        XCTAssertEqual(ProviderRecoveryCardPalette.washOpacity, 0.09, accuracy: 0.001)
        XCTAssertEqual(ProviderRecoveryCardPalette.washColors.count, 3)

        let expectedIndices = [4, 5, 0] // purple → blue → green
        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
            let surface = ProviderRecoveryCardPalette.baseSurface
                .mechanicianResolved(in: appearance)
            let title = NSColor.labelColor.mechanicianResolved(in: appearance)
            let detail = NSColor.nSecondaryText.mechanicianResolved(in: appearance)
            let icon = NSColor.nPurpleText.mechanicianResolved(in: appearance)
            let actualStops = MagicLaserSpectrum.resolvedColors(
                ProviderRecoveryCardPalette.washColors,
                in: appearance)
            let expectedStops = MagicLaserSpectrum.resolvedColors(
                expectedIndices.map { MagicLaserSpectrum.colors[$0] },
                in: appearance)

            for (actual, expected) in zip(actualStops, expectedStops) {
                XCTAssertEqual(actual.redComponent, expected.redComponent, accuracy: 0.001)
                XCTAssertEqual(actual.greenComponent, expected.greenComponent, accuracy: 0.001)
                XCTAssertEqual(actual.blueComponent, expected.blueComponent, accuracy: 0.001)

                let washedSurface = composite(
                    actual,
                    alpha: CGFloat(ProviderRecoveryCardPalette.washOpacity),
                    over: surface)
                for ink in [title, detail, icon] {
                    XCTAssertGreaterThanOrEqual(
                        contrast(ink, washedSurface),
                        4.5,
                        "recovery-card copy must remain readable at every wash stop in \(appearanceName)")
                }
            }
        }
    }

    func testProviderRecoveryRailKeepsAllSixBrandRaysInLogoOrder() throws {
        XCTAssertEqual(
            ProviderRecoveryCardPalette.railColors.count,
            MagicLaserSpectrum.colors.count)

        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
            let rail = MagicLaserSpectrum.resolvedColors(
                ProviderRecoveryCardPalette.railColors,
                in: appearance)
            let expected = MagicLaserSpectrum.resolvedColors(in: appearance)

            for (actual, expected) in zip(rail, expected) {
                XCTAssertEqual(actual.redComponent, expected.redComponent, accuracy: 0.001)
                XCTAssertEqual(actual.greenComponent, expected.greenComponent, accuracy: 0.001)
                XCTAssertEqual(actual.blueComponent, expected.blueComponent, accuracy: 0.001)
            }
        }
    }

    func testReadableSecondaryTextClearsMarketplaceCardAndChipSurfaces() throws {
        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
            let surface = NSColor.nSurface.mechanicianResolved(in: appearance)
            let background = NSColor.nBg.mechanicianResolved(in: appearance)
            let ink = NSColor.nSecondaryText.mechanicianResolved(in: appearance)
            let chip = composite(ink, alpha: 0.14, over: surface)

            XCTAssertGreaterThanOrEqual(
                contrast(ink, surface),
                4.5,
                "caption copy must remain readable on cards in \(appearanceName)")
            XCTAssertGreaterThanOrEqual(
                contrast(ink, background),
                4.5,
                "caption copy must remain readable between cards in \(appearanceName)")
            XCTAssertGreaterThanOrEqual(
                contrast(ink, chip),
                4.5,
                "caption copy must remain readable on tinted chips in \(appearanceName)")
        }
    }

    func testSyntaxAndDiffPaletteMeetsContrastOnRenderedRowSurfaces() throws {
        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
            let surface = NSColor.nSurface.mechanicianResolved(in: appearance)
            let codeBlock = NSColor.nBg.mechanicianResolved(in: appearance)
            let addition = SyntaxHighlightPalette.additionBackground
                .mechanicianResolved(in: appearance)
            let deletion = SyntaxHighlightPalette.deletionBackground
                .mechanicianResolved(in: appearance)
            let syntaxColors: [NSColor] = [
                SyntaxHighlightPalette.base,
                SyntaxHighlightPalette.comment,
                SyntaxHighlightPalette.string,
                SyntaxHighlightPalette.number,
                SyntaxHighlightPalette.keyword,
            ]

            for foreground in syntaxColors {
                let resolved = foreground.mechanicianResolved(in: appearance)
                for background in [surface, codeBlock, addition, deletion] {
                    XCTAssertGreaterThanOrEqual(
                        contrast(resolved, background),
                        4.5,
                        "syntax token must remain readable on every diff row in \(appearanceName)")
                }
            }

            XCTAssertGreaterThanOrEqual(
                contrast(
                    SyntaxHighlightPalette.additionMarker.mechanicianResolved(in: appearance),
                    addition),
                4.5)
            XCTAssertGreaterThanOrEqual(
                contrast(
                    SyntaxHighlightPalette.deletionMarker.mechanicianResolved(in: appearance),
                    deletion),
                4.5)
            XCTAssertGreaterThanOrEqual(
                contrast(
                    SyntaxHighlightPalette.hunk.mechanicianResolved(in: appearance),
                    surface),
                4.5)
            XCTAssertGreaterThanOrEqual(
                contrast(
                    SyntaxHighlightPalette.header.mechanicianResolved(in: appearance),
                    surface),
                4.5)
        }
    }

    func testWorkflowBadgeInkMeetsSmallTextContrastOnItsTintedCapsule() throws {
        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
            let surface = NSColor.nSurface.mechanicianResolved(in: appearance)
            for status in [
                WorkflowStatus.pending,
                .running,
                .completed,
                .failed,
                .killed,
                .paused,
                .stopped,
            ] {
                let ink = status.badgeTextNSColor.mechanicianResolved(in: appearance)
                let wash = status.badgeFillNSColor.mechanicianResolved(in: appearance)
                let capsule = composite(
                    wash,
                    alpha: appearanceName == .darkAqua ? 0.07 : 0.14,
                    over: surface)
                XCTAssertGreaterThanOrEqual(
                    contrast(ink, capsule),
                    4.5,
                    "\(status.rawValue) badge ink must remain readable in \(appearanceName)")
            }
        }
    }

    func testHighlighterAndDiffRendererActuallyEmitTheAdaptiveTokenRuns() {
        let source = #"let answer = "forty-two" // visible comment"#
        let highlighted = SyntaxHighlighter.highlight(
            source,
            language: "swift",
            fontSize: 11)
        XCTAssertEqual(String(highlighted.characters), source)
        XCTAssertGreaterThanOrEqual(
            highlighted.runs.count,
            5,
            "base, keyword, string, and comment content must reach distinct attributed runs")

        let added = SyntaxHighlighter.diffLine(
            "+" + source,
            language: "swift",
            fontSize: 11)
        let removed = SyntaxHighlighter.diffLine(
            "-" + source,
            language: "swift",
            fontSize: 11)
        XCTAssertEqual(String(added.text.characters), "+" + source)
        XCTAssertEqual(String(removed.text.characters), "-" + source)
        XCTAssertGreaterThan(added.text.runs.count, highlighted.runs.count)
        XCTAssertGreaterThan(removed.text.runs.count, highlighted.runs.count)
        XCTAssertNotEqual(
            String(describing: added.background),
            String(describing: removed.background),
            "added and removed rows must not collapse onto one tint")
    }

    private func contrast(_ lhs: NSColor, _ rhs: NSColor) -> Double {
        let a = luminance(lhs)
        let b = luminance(rhs)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    private func composite(_ foreground: NSColor, alpha: CGFloat, over background: NSColor) -> NSColor {
        let fg = foreground.usingColorSpace(.sRGB)!
        let bg = background.usingColorSpace(.sRGB)!
        return NSColor(
            srgbRed: fg.redComponent * alpha + bg.redComponent * (1 - alpha),
            green: fg.greenComponent * alpha + bg.greenComponent * (1 - alpha),
            blue: fg.blueComponent * alpha + bg.blueComponent * (1 - alpha),
            alpha: 1)
    }

    private func luminance(_ source: NSColor) -> Double {
        let color = source.usingColorSpace(.sRGB)!
        func channel(_ component: CGFloat) -> Double {
            let value = Double(component)
            return value <= 0.03928
                ? value / 12.92
                : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(color.redComponent)
            + 0.7152 * channel(color.greenComponent)
            + 0.0722 * channel(color.blueComponent)
    }
}
