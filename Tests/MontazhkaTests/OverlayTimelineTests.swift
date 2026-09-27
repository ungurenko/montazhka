import Foundation
import Testing

@testable import MontazhkaKit

/// Анимация держится за слово исходника: правки ленты двигают её вместе со словом.
@Suite("Overlay timeline")
struct OverlayTimelineTests {
    private let source = MediaReference(path: "/tmp/a.mov")
    private let other = MediaReference(path: "/tmp/b.mov")

    private func overlay(
        at sourceTime: Double, align: OverlayAlign = .start, payoffAt: Double = 0, duration: Double = 2
    ) -> ProjectOverlay {
        ProjectOverlay(
            id: UUID(), media: MediaReference(path: "/tmp/overlay.mov"),
            anchor: OverlayAnchor(sourceID: source.id, sourceTime: sourceTime, wordText: "монтаж"),
            align: align, payoffAt: payoffAt, duration: duration, position: .full, scale: 1)
    }

    private func resolved(_ overlay: ProjectOverlay, _ clips: [Clip]) -> ResolvedOverlay {
        OverlayTimeline.resolve([overlay], clips: clips)[0]
    }

    private func isClose(_ a: Double?, _ b: Double) -> Bool {
        a.map { abs($0 - b) < 1e-9 } ?? false
    }

    @Test("a cut before the anchor pulls the window earlier by the cut length")
    func cutBeforeAnchorShiftsWindow() {
        let item = overlay(at: 10)
        let clips = [Clip(source: source, start: 0, end: 20)]
        let before = resolved(item, clips)
        #expect(before.status == .visible)
        #expect(isClose(before.window.from, 10) && isClose(before.window.to, 12))

        let cut = TimelineOps.removingSourceRanges(clips: clips, sourcePath: "/tmp/a.mov", ranges: [(2, 5)])
        let after = resolved(item, cut)
        #expect(after.status == .visible)
        #expect(isClose(after.window.from, 7) && isClose(after.window.to, 9))
        #expect(isClose(after.anchorTimeline, 7))
        #expect(after.mediaStart == 0)
    }

    @Test("deleting the anchor word hides the overlay as anchorCut")
    func deletedAnchorWord() {
        let clips = TimelineOps.removingSourceRanges(
            clips: [Clip(source: source, start: 0, end: 20)], sourcePath: "/tmp/a.mov", ranges: [(9.9, 10.5)])
        let result = resolved(overlay(at: 10), clips)
        #expect(result.status == .anchorCut)
        #expect(result.anchorTimeline == nil)
        #expect(result.occurrences == 0)
        #expect(result.window.from == result.window.to)
    }

    @Test("moving the clip with the anchor carries the overlay along")
    func movedClipCarriesOverlay() {
        let intro = Clip(source: source, start: 0, end: 5)
        let story = Clip(source: source, start: 10, end: 15)
        let item = overlay(at: 12)
        #expect(isClose(resolved(item, [intro, story]).window.from, 7))
        let moved = resolved(item, [story, intro])
        #expect(moved.status == .visible)
        #expect(isClose(moved.window.from, 2) && isClose(moved.window.to, 4))
    }

    @Test("a payoff later than the anchor starts the file mid-way at the timeline start")
    func payoffBeforeTimelineStart() {
        let item = overlay(at: 0.5, align: .payoff, payoffAt: 1.5, duration: 3)
        let result = resolved(item, [Clip(source: source, start: 0, end: 10)])
        #expect(result.status == .visible)
        #expect(isClose(result.mediaStart, 1))
        #expect(result.window.from == 0)
        #expect(isClose(result.window.to, 2))
        #expect(isClose(result.anchorTimeline, 0.5))
    }

    @Test("the payoff lands on the anchor word")
    func payoffLandsOnAnchor() {
        let item = overlay(at: 6, align: .payoff, payoffAt: 1.5, duration: 3)
        let result = resolved(item, [Clip(source: source, start: 0, end: 10)])
        #expect(isClose(result.window.from, 4.5) && isClose(result.window.to, 7.5))
        #expect(result.mediaStart == 0)
    }

    @Test("the tail is clipped at the timeline end, and a sliver under 0.1 s is dropped")
    func tailClippedAtEnd() {
        let clips = [Clip(source: source, start: 0, end: 10)]
        let clipped = resolved(overlay(at: 9, duration: 3), clips)
        #expect(clipped.status == .visible)
        #expect(isClose(clipped.window.from, 9) && isClose(clipped.window.to, 10))

        let sliver = resolved(overlay(at: 9.95, duration: 3), clips)
        #expect(sliver.status == .tooShort)
        #expect(sliver.window.from == sliver.window.to)
        #expect(isClose(sliver.anchorTimeline, 9.95))
    }

    @Test("the same source moment used twice shows at its first place and reports both")
    func repeatedMomentUsesFirst() {
        let clips = [
            Clip(source: source, start: 0, end: 5),
            Clip(source: other, start: 0, end: 3),
            Clip(source: source, start: 2, end: 6),
        ]
        let anchor = overlay(at: 3).anchor
        let times = OverlayTimeline.timelineTimes(of: anchor, clips: clips)
        #expect(times.count == 2 && isClose(times.first, 3) && isClose(times.last, 9))

        let result = resolved(overlay(at: 3), clips)
        #expect(result.occurrences == 2)
        #expect(isClose(result.anchorTimeline, 3))
        #expect(isClose(result.window.from, 3))
    }

    @Test("splitting the clip exactly at the anchor still counts one place on the timeline")
    func splitAtAnchorIsOnePlace() {
        let clips = [Clip(source: source, start: 0, end: 5), Clip(source: source, start: 5, end: 10)]
        let result = resolved(overlay(at: 5), clips)
        #expect(result.occurrences == 1)
        #expect(isClose(result.anchorTimeline, 5))
    }

    @Test("a timeline moment becomes an anchor on the word under or after it")
    func anchorSnapsToWord() {
        let clips = [Clip(source: source, start: 0, end: 5), Clip(source: source, start: 8, end: 12)]
        let words = TranscriptTimelineMapper.make(
            clips: clips,
            transcripts: [
                TranscriptWord(sourceID: source.id, text: "привет", start: 1, end: 1.5, confidence: 1),
                TranscriptWord(sourceID: source.id, text: "монтаж", start: 9, end: 9.6, confidence: 1),
            ]
        ).words

        let under = OverlayTimeline.anchor(atTimeline: 6.2, clips: clips, words: words)
        #expect(under == OverlayAnchor(sourceID: source.id, sourceTime: 9, wordText: "монтаж"))
        let gap = OverlayTimeline.anchor(atTimeline: 3, clips: clips, words: words)
        #expect(gap == OverlayAnchor(sourceID: source.id, sourceTime: 9, wordText: "монтаж"))

        let raw = OverlayTimeline.anchor(atTimeline: 6.2, clips: clips, words: nil)
        #expect(raw?.sourceID == source.id && raw?.wordText == nil && isClose(raw?.sourceTime, 9.2))
        let afterLastWord = OverlayTimeline.anchor(atTimeline: 8, clips: clips, words: words)
        #expect(afterLastWord?.wordText == nil && isClose(afterLastWord?.sourceTime, 11))
        #expect(OverlayTimeline.anchor(atTimeline: 9.5, clips: clips, words: words) == nil)

        // Якорь от слова ложится на ленте ровно на начало этого слова.
        let placed = OverlayTimeline.timelineTimes(of: under!, clips: clips)
        #expect(placed.count == 1 && isClose(placed.first, 6))
    }
}
