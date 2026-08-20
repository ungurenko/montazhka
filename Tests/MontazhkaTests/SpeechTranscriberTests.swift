import Foundation
import Testing

@testable import MontazhkaKit

@Suite
struct SpeechTranscriberTests {
    @Test
    func testTranscriptWordKeepsExactEndTime() {
        let word = TranscriptWord(
            sourceID: UUID(), text: "Привет", start: 1.25,
            end: 1.8, confidence: 0.9)
        #expect(abs((word.duration) - (0.55)) <= (0.0001))
    }

    @Test
    func testTranscriptDocumentRoundTripsWithVersionAndRussianModel() throws {
        let words = [
            TranscriptWord(
                sourceID: UUID(), text: "Привет", start: 0,
                end: 0.5, confidence: 0.98)
        ]
        let data = try JSONEncoder().encode(TranscriptDocument(words: words))
        let decoded = try JSONDecoder().decode(TranscriptDocument.self, from: data)

        #expect((decoded.schemaVersion) == (2))
        #expect((decoded.language) == ("ru"))
        #expect((decoded.words) == (words))
    }
}
