import XCTest
@testable import Montazhka

final class TimelineViewportTests: XCTestCase {
    func testDragPreviewNeverUsesFullWidthOfALongClip() {
        XCTAssertEqual(TimelineDragPreviewMath.width(forClipWidth: 12_000), 240)
        XCTAssertEqual(TimelineDragPreviewMath.width(forClipWidth: 160), 160)
        XCTAssertEqual(TimelineDragPreviewMath.width(forClipWidth: 20), 80)
    }

    func testScaleStaysWithinEditingLimits() {
        XCTAssertEqual(TimelineViewportMath.clampedPixelsPerSecond(2), 3)
        XCTAssertEqual(TimelineViewportMath.clampedPixelsPerSecond(40), 40)
        XCTAssertEqual(TimelineViewportMath.clampedPixelsPerSecond(11_000), 240)
    }

    func testOffsetClampsToScrollableContent() {
        XCTAssertEqual(
            TimelineViewportMath.clampedOffset(-20, contentWidth: 1_000, viewportWidth: 300),
            0,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            TimelineViewportMath.clampedOffset(900, contentWidth: 1_000, viewportWidth: 300),
            700,
            accuracy: 0.0001
        )
    }

    func testZoomKeepsTimeUnderPointerFixed() {
        let offset = TimelineViewportMath.offsetKeepingAnchor(
            currentOffset: 100,
            anchorX: 200,
            oldPixelsPerSecond: 20,
            newPixelsPerSecond: 40,
            leadingInset: 12
        )

        XCTAssertEqual(offset, 388, accuracy: 0.0001)
    }

    func testPlaybackFollowingStartsAtMidpointAndCentersOffscreenPlayhead() {
        XCTAssertEqual(
            TimelineViewportMath.followOffset(
                playheadX: 600, currentOffset: 400, viewportWidth: 500
            ),
            400,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            TimelineViewportMath.followOffset(
                playheadX: 700, currentOffset: 400, viewportWidth: 500
            ),
            450,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            TimelineViewportMath.followOffset(
                playheadX: 100, currentOffset: 400, viewportWidth: 500
            ),
            -150,
            accuracy: 0.0001
        )
    }
}
