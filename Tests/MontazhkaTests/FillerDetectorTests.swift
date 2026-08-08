import XCTest
@testable import Montazhka

final class FillerDetectorTests: XCTestCase {
    func testMapsSingleWordAndPhraseFromSourceTimeToTimeline() {
        let sourceID = UUID()
        let clip = Clip(source: MediaReference(path: "/tmp/take.mov", id: sourceID),
                        start: 10, end: 20)
        let tokens = [
            TranscriptToken(sourceID: sourceID, text: "Ну", start: 12, duration: 0.3, confidence: 0.9),
            TranscriptToken(sourceID: sourceID, text: "как", start: 15, duration: 0.2, confidence: 0.9),
            TranscriptToken(sourceID: sourceID, text: "бы", start: 15.25, duration: 0.2, confidence: 0.9),
            TranscriptToken(sourceID: sourceID, text: "работает", start: 16, duration: 0.5, confidence: 0.9)
        ]

        let candidates = FillerDetector.findCandidates(clips: [clip], tokens: tokens)

        XCTAssertEqual(candidates.map(\.text), ["Ну", "как бы"])
        XCTAssertEqual(candidates[0].start, 1.92, accuracy: 0.001)
        XCTAssertEqual(candidates[0].end, 2.38, accuracy: 0.001)
        XCTAssertEqual(candidates[1].start, 4.92, accuracy: 0.001)
        XCTAssertEqual(candidates[1].end, 5.53, accuracy: 0.001)
    }

    func testDoesNotSuggestFillerOutsideVisibleClipRange() {
        let sourceID = UUID()
        let clip = Clip(source: MediaReference(path: "/tmp/take.mov", id: sourceID),
                        start: 10, end: 20)
        let tokens = [
            TranscriptToken(sourceID: sourceID, text: "эм", start: 2, duration: 0.2, confidence: 1)
        ]

        XCTAssertTrue(FillerDetector.findCandidates(clips: [clip], tokens: tokens).isEmpty)
    }
}
