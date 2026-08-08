import Foundation
import XCTest
@testable import Montazhka

final class SmartEditDomainTests: XCTestCase {
    func testMapperDuplicatesWordsWhenSourceIsUsedTwiceWithoutLeakingPaths() {
        let source = MediaReference(path: "/private/secret/video.mov")
        let clips = [
            Clip(source: source, start: 0, end: 3),
            Clip(source: source, start: 0, end: 3)
        ]
        let transcript = [
            TranscriptWord(sourceID: source.id, text: "Привет", start: 1, end: 1.4, confidence: 0.9)
        ]

        let map = TranscriptTimelineMapper.make(clips: clips, transcripts: transcript)

        XCTAssertEqual(map.words.map(\.wordID), ["w000001", "w000002"])
        XCTAssertEqual(map.words.map(\.timelineStart), [1, 4])
        let encoded = try! JSONEncoder().encode(map.words.map(\.publicPayload))
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("secret"))
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains(source.id.uuidString))
    }

    func testRangeCannotCrossClipBoundary() {
        let firstSource = MediaReference(path: "/tmp/a.mov")
        let secondSource = MediaReference(path: "/tmp/b.mov")
        let map = TranscriptTimelineMapper.make(
            clips: [Clip(source: firstSource, start: 0, end: 2),
                    Clip(source: secondSource, start: 0, end: 2)],
            transcripts: [
                TranscriptWord(sourceID: firstSource.id, text: "раз", start: 1, end: 1.2, confidence: 1),
                TranscriptWord(sourceID: secondSource.id, text: "два", start: 1, end: 1.2, confidence: 1)
            ])

        XCTAssertNil(map.range(firstWordID: "w000001", lastWordID: "w000002"))
    }

    func testConservativeSelectionAndOverlapMerging() {
        XCTAssertTrue(SmartEditSelection.shouldEnable(kind: .falseStart, confidence: 0.90,
                                                       hasSafeBoundary: true))
        XCTAssertFalse(SmartEditSelection.shouldEnable(kind: .semanticRepeat, confidence: 1,
                                                        hasSafeBoundary: true))
        XCTAssertFalse(SmartEditSelection.shouldEnable(kind: .duplicateTake, confidence: 0.89,
                                                        hasSafeBoundary: true))
        let merged = SmartEditRanges.merged([(1, 2), (1.5, 3), (3, 4)])
        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged[0].start, 1)
        XCTAssertEqual(merged[0].end, 3)
    }

    func testBoundaryResolverRejectsLoudJoin() {
        let source = MediaReference(path: "/tmp/a.mov")
        let clip = Clip(source: source, start: 0, end: 5)
        let transcript = [TranscriptWord(sourceID: source.id, text: "эм", start: 2, end: 2.4, confidence: 1)]
        let map = TranscriptTimelineMapper.make(clips: [clip], transcripts: transcript)
        let words = map.range(firstWordID: "w000001", lastWordID: "w000001")!

        XCTAssertNil(SmartCutBoundaryResolver.resolve(
            words: words, clip: clip, clipTimelineStart: 0,
            peaks: [Float](repeating: 0.1, count: 500), projectThresholdDB: -40))
    }
}
