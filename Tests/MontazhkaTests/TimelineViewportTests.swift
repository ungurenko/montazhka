import Testing

@testable import MontazhkaKit

@Suite
struct TimelineViewportTests {
    @Test
    func testLayoutPreservesClipOrderAndStarts() {
        let clips = [
            Clip(sourcePath: "/tmp/a.mov", start: 0, end: 2),
            Clip(sourcePath: "/tmp/b.mov", start: 4, end: 7),
            Clip(sourcePath: "/tmp/c.mov", start: 10, end: 14),
        ]

        let layout = TimelineLayout(clips: clips)

        #expect(layout.items.map(\.start) == [0, 2, 5])
        #expect(layout.items.map(\.clip.id) == clips.map(\.id))
        #expect(layout.duration == 9)
    }

    @Test
    func testDragPreviewNeverUsesFullWidthOfALongClip() {
        #expect((TimelineDragPreviewMath.width(forClipWidth: 12_000)) == (240))
        #expect((TimelineDragPreviewMath.width(forClipWidth: 160)) == (160))
        #expect((TimelineDragPreviewMath.width(forClipWidth: 20)) == (80))
    }

    @Test
    func testScaleStaysWithinEditingLimits() {
        #expect((TimelineViewportMath.clampedPixelsPerSecond(2)) == (3))
        #expect((TimelineViewportMath.clampedPixelsPerSecond(40)) == (40))
        #expect((TimelineViewportMath.clampedPixelsPerSecond(11_000)) == (240))
    }

    @Test
    func testOffsetClampsToScrollableContent() {
        #expect(
            abs((TimelineViewportMath.clampedOffset(-20, contentWidth: 1_000, viewportWidth: 300)) - (0)) <= (0.0001))
        #expect(
            abs((TimelineViewportMath.clampedOffset(900, contentWidth: 1_000, viewportWidth: 300)) - (700)) <= (0.0001))
    }

    @Test
    func testZoomKeepsTimeUnderPointerFixed() {
        let offset = TimelineViewportMath.offsetKeepingAnchor(
            currentOffset: 100,
            anchorX: 200,
            oldPixelsPerSecond: 20,
            newPixelsPerSecond: 40,
            leadingInset: 12
        )

        #expect(abs((offset) - (388)) <= (0.0001))
    }

    @Test
    func testPlaybackFollowingStartsAtMidpointAndCentersOffscreenPlayhead() {
        #expect(
            abs(
                (TimelineViewportMath.followOffset(
                    playheadX: 600, currentOffset: 400, viewportWidth: 500
                )) - (400)) <= (0.0001))
        #expect(
            abs(
                (TimelineViewportMath.followOffset(
                    playheadX: 700, currentOffset: 400, viewportWidth: 500
                )) - (450)) <= (0.0001))
        #expect(
            abs(
                (TimelineViewportMath.followOffset(
                    playheadX: 100, currentOffset: 400, viewportWidth: 500
                )) - (-150)) <= (0.0001))
    }
}
