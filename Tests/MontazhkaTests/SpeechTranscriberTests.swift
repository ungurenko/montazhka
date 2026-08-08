import XCTest
@testable import Montazhka

final class SpeechTranscriberTests: XCTestCase {
    func testTranscriptWordKeepsExactEndTime() {
        let word = TranscriptWord(sourceID: UUID(), text: "Привет", start: 1.25,
                                  end: 1.8, confidence: 0.9)
        XCTAssertEqual(word.duration, 0.55, accuracy: 0.0001)
    }

    func testTranscriptDocumentRoundTripsWithVersionAndRussianModel() throws {
        let words = [TranscriptWord(sourceID: UUID(), text: "Привет", start: 0,
                                    end: 0.5, confidence: 0.98)]
        let data = try JSONEncoder().encode(TranscriptDocument(words: words))
        let decoded = try JSONDecoder().decode(TranscriptDocument.self, from: data)

        XCTAssertEqual(decoded.schemaVersion, 2)
        XCTAssertEqual(decoded.language, "ru")
        XCTAssertEqual(decoded.words, words)
    }
}
