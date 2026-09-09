import AppKit
import XCTest
@testable import Mechanician

@MainActor
final class ComposerRoadSignImageTests: XCTestCase {
    func testRendererReturnsNonTemplateImageAtRequestedLogicalSizeAndTwoXScale() throws {
        let size: CGFloat = 17
        let image = try XCTUnwrap(ComposerRoadSignImage.image(kind: .stop, size: size))

        XCTAssertEqual(image.size, NSSize(width: size, height: size))
        XCTAssertFalse(image.isTemplate)
        XCTAssertGreaterThanOrEqual(
            image.representations.map(\.pixelsWide).max() ?? 0,
            Int(size * 2))
        XCTAssertGreaterThanOrEqual(
            image.representations.map(\.pixelsHigh).max() ?? 0,
            Int(size * 2))
    }

    func testCacheKeysByKindAndLogicalSize() throws {
        let first = try XCTUnwrap(ComposerRoadSignImage.image(kind: .stop, size: 17))
        let repeated = try XCTUnwrap(ComposerRoadSignImage.image(kind: .stop, size: 17))
        let otherKind = try XCTUnwrap(ComposerRoadSignImage.image(kind: .send, size: 17))
        let otherSize = try XCTUnwrap(ComposerRoadSignImage.image(kind: .stop, size: 18))

        XCTAssertTrue(first === repeated)
        XCTAssertFalse(first === otherKind)
        XCTAssertFalse(first === otherSize)
    }

    func testRendererRejectsInvalidLogicalSizes() {
        XCTAssertNil(ComposerRoadSignImage.image(kind: .stop, size: 0))
        XCTAssertNil(ComposerRoadSignImage.image(kind: .stop, size: -1))
        XCTAssertNil(ComposerRoadSignImage.image(kind: .stop, size: .infinity))
        XCTAssertNil(ComposerRoadSignImage.image(kind: .stop, size: .nan))
    }

    func testDeliveryMenuUsesTheSharedCachedRenderer() throws {
        let menuImage = try XCTUnwrap(ComposerDeliveryMenuView.icon(.curveAhead))
        let sharedImage = try XCTUnwrap(ComposerRoadSignImage.image(
            kind: .curveAhead,
            size: ComposerDeliveryMenuView.iconSize))

        XCTAssertTrue(menuImage === sharedImage)
    }
}
