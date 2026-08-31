import Foundation
import Testing

@testable import MontazhkaKit

@Suite
struct SmartEditDomainTests {
    @Test
    func testMapperDuplicatesWordsWhenSourceIsUsedTwiceWithoutLeakingPaths() {
        let source = MediaReference(path: "/private/secret/video.mov")
        let clips = [
            Clip(source: source, start: 0, end: 3),
            Clip(source: source, start: 0, end: 3),
        ]
        let transcript = [
            TranscriptWord(sourceID: source.id, text: "Привет", start: 1, end: 1.4, confidence: 0.9)
        ]

        let map = TranscriptTimelineMapper.make(clips: clips, transcripts: transcript)

        #expect((map.words.map(\.wordID)) == (["w000001", "w000002"]))
        #expect((map.words.map(\.timelineStart)) == ([1, 4]))
        let encoded = try! JSONEncoder().encode(map.words.map(\.publicPayload))
        #expect(!(String(decoding: encoded, as: UTF8.self).contains("secret")))
        #expect(!(String(decoding: encoded, as: UTF8.self).contains(source.id.uuidString)))
    }

    @Test
    func testRangeCannotCrossClipBoundary() {
        let firstSource = MediaReference(path: "/tmp/a.mov")
        let secondSource = MediaReference(path: "/tmp/b.mov")
        let map = TranscriptTimelineMapper.make(
            clips: [
                Clip(source: firstSource, start: 0, end: 2),
                Clip(source: secondSource, start: 0, end: 2),
            ],
            transcripts: [
                TranscriptWord(sourceID: firstSource.id, text: "раз", start: 1, end: 1.2, confidence: 1),
                TranscriptWord(sourceID: secondSource.id, text: "два", start: 1, end: 1.2, confidence: 1),
            ])

        #expect((map.range(firstWordID: "w000001", lastWordID: "w000002")) == nil)
    }

    @Test
    func testConservativeSelectionAndOverlapMerging() {
        #expect(
            SmartEditSelection.shouldEnable(
                kind: .falseStart, confidence: 0.90,
                hasSafeBoundary: true))
        #expect(
            !(SmartEditSelection.shouldEnable(
                kind: .semanticRepeat, confidence: 1,
                hasSafeBoundary: true)))
        #expect(
            !(SmartEditSelection.shouldEnable(
                kind: .duplicateTake, confidence: 0.89,
                hasSafeBoundary: true)))
        let merged = SmartEditRanges.merged([(1, 2), (1.5, 3), (3, 4)])
        #expect((merged.count) == (2))
        #expect((merged[0].start) == (1))
        #expect((merged[0].end) == (3))
    }

    @Test
    func testAnalysisCanRestartAfterFailureButNotWhileWorking() {
        #expect(SmartEditStatus.idle.allowsAnalysisStart)
        #expect(SmartEditStatus.failed("Сеть недоступна").allowsAnalysisStart)
        #expect(!(SmartEditStatus.proposing.allowsAnalysisStart))
        #expect(!(SmartEditStatus.ready.allowsAnalysisStart))
    }

    @Test
    func testBoundaryResolverRejectsLoudJoin() {
        let source = MediaReference(path: "/tmp/a.mov")
        let clip = Clip(source: source, start: 0, end: 5)
        let transcript = [TranscriptWord(sourceID: source.id, text: "эм", start: 2, end: 2.4, confidence: 1)]
        let map = TranscriptTimelineMapper.make(clips: [clip], transcripts: transcript)
        let words = map.range(firstWordID: "w000001", lastWordID: "w000001")!

        #expect(
            (SmartCutBoundaryResolver.resolve(
                words: words, clip: clip, clipTimelineStart: 0,
                peaks: [Float](repeating: 0.1, count: 500), projectThresholdDB: -40)) == nil)
    }

    @Test
    func testBoundaryResolverUsesQuietPointsAroundWords() throws {
        let source = MediaReference(path: "/tmp/a.mov")
        let clip = Clip(source: source, start: 1, end: 9)
        let transcript = [
            TranscriptWord(sourceID: source.id, text: "я", start: 2.1, end: 2.2, confidence: 0.95),
            TranscriptWord(sourceID: source.id, text: "точнее", start: 2.25, end: 2.55, confidence: 0.94),
        ]
        let map = TranscriptTimelineMapper.make(clips: [clip], transcripts: transcript)
        let words = try #require(map.range(firstWordID: "w000001", lastWordID: "w000002"))
        var peaks = [Float](repeating: 0.08, count: 1_000)
        for index in 198..<212 { peaks[index] = 0.001 }
        for index in 255..<270 { peaks[index] = 0.001 }

        let boundary = SmartCutBoundaryResolver.resolve(
            words: words,
            clip: clip,
            clipTimelineStart: 0,
            peaks: peaks,
            projectThresholdDB: -40)

        #expect(boundary != nil)
        #expect((boundary?.timelineEnd ?? 0) - (boundary?.timelineStart ?? 0) >= 0.25)
    }
}
