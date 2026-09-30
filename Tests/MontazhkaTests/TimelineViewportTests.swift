import AppKit
import Observation
import Testing

@testable import MontazhkaKit

@Suite
struct TimelineViewportTests {
    @Test(arguments: [24.0, 240.0])
    func croppedWaveformMatchesFullDrawing(pps: Double) {
        let clip = Clip(sourcePath: "/tmp/wave.mov", start: 3, end: 3603)
        let peaks = (0..<360_400).map { Float($0 % 97) / 97 }
        let size = CGSize(width: clip.duration * pps, height: 80)
        let full = TimelineWaveformFixture.original(clip: clip, peaks: peaks, size: size)
        // Fractional offsets, a trim-shifted origin and the far end preserve the 2px phase.
        for contentX in [12.0, 37.25] {
            for offset in [0.0, 876.5, size.width - 1100] {
                let viewport = CGRect(x: offset, y: 0, width: 1200, height: 100)
                let range = TimelineDrawingRange.local(contentX: contentX, width: size.width, viewport: viewport)
                let cropped = TimelineWaveformDrawing.path(clip: clip, peaks: peaks, size: size, range: range)
                #expect(
                    TimelineWaveformFixture.pixels(cropped, offset: offset - contentX)
                        == TimelineWaveformFixture.pixels(full, offset: offset - contentX))
                #expect(range.upperBound - range.lowerBound <= 1200 + 2 * TimelineDrawingRange.overscan)
            }
        }
        let hidden = TimelineDrawingRange.local(
            contentX: size.width + 1500, width: 100, viewport: CGRect(x: 0, y: 0, width: 1200, height: 100))
        #expect(hidden.isEmpty)
    }

    @Test @MainActor
    func drawingViewportTracksProgrammaticScrollAndResize() {
        let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 400, height: 100))
        scroll.documentView = NSView(frame: CGRect(x: 0, y: 0, width: 4000, height: 100))
        let proxy = TimelineViewportProxy()
        var manualChanges = 0
        proxy.onManualScroll = { manualChanges += 1 }
        proxy.attach(to: scroll)
        proxy.setHorizontalOffset(300)
        #expect(abs(proxy.drawingState.bounds.minX - 300) < 0.001)
        #expect(manualChanges == 0)
        scroll.contentView.setBoundsSize(CGSize(width: 500, height: 100))
        NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        #expect(abs(proxy.drawingState.bounds.width - 500) < 0.001)
        #expect(manualChanges == 0)
        scroll.contentView.postsBoundsChangedNotifications = false
        scroll.contentView.setBoundsSize(CGSize(width: 700, height: 100))
        NotificationCenter.default.post(name: NSView.frameDidChangeNotification, object: scroll.contentView)
        #expect(abs(proxy.drawingState.bounds.width - 700) < 0.001)
        #expect(manualChanges == 0)
        scroll.contentView.postsBoundsChangedNotifications = true
        scroll.contentView.scroll(to: CGPoint(x: 600, y: 0))
        NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        #expect(abs(proxy.drawingState.bounds.minX - 600) < 0.001)
        #expect(manualChanges == 1)
    }

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
