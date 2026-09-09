import XCTest
@testable import Mechanician

final class InspectorPreviewSplitTests: XCTestCase {
    func testPreservesStoredPreviewHeightWhenThereIsRoom() {
        XCTAssertEqual(
            InspectorPreviewSizing.resolvedHeight(
                storedHeight: 320,
                availableHeight: 760,
                minimumTopHeight: 200,
                minimumPreviewHeight: 220,
                maximumPreviewHeight: 520
            ),
            320
        )
    }

    func testKeepsPreviewUsableWhenStoredHeightIsTooSmall() {
        XCTAssertEqual(
            InspectorPreviewSizing.resolvedHeight(
                storedHeight: 120,
                availableHeight: 760,
                minimumTopHeight: 200,
                minimumPreviewHeight: 220,
                maximumPreviewHeight: 520
            ),
            220
        )
    }

    func testClampsPreviewOnlyWhenWindowCannotFitSavedHeight() {
        XCTAssertEqual(
            InspectorPreviewSizing.resolvedHeight(
                storedHeight: 320,
                availableHeight: 410,
                minimumTopHeight: 180,
                minimumPreviewHeight: 220,
                maximumPreviewHeight: 520
            ),
            220
        )
    }
}
