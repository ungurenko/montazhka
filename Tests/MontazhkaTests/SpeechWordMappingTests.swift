import FluidAudio
import Foundation
import Testing

@testable import MontazhkaKit

@Suite
struct SpeechWordMappingTests {
    private let sourceID = UUID()

    private func tokens(_ specs: [(String, Double, Double, Float)]) -> [TokenTiming] {
        specs.map { TokenTiming(token: $0.0, tokenId: 0, startTime: $0.1, endTime: $0.2, confidence: $0.3) }
    }

    @Test
    func testMakeWordsBuildsWordsWithExactBoundsAndConfidence() {
        let words = ParakeetTranscriber.makeWords(
            sourceID: sourceID,
            tokenTimings: tokens([
                ("▁Привет", 1.25, 1.8, 0.9),
                ("▁мир", 1.8, 2.4, 0.8),
            ]),
            fallbackConfidence: 0.0)

        #expect(words.count == 2)
        #expect(words[0].text == "Привет")
        #expect(words[0].sourceID == sourceID)
        #expect(words[0].start == 1.25)
        #expect(words[0].end == 1.8)
        #expect(abs((words[0].confidence) - (0.9)) <= (0.001))
        #expect(words[1].text == "мир")
        #expect(words[1].start == 1.8)
        #expect(words[1].end == 2.4)
        #expect(abs((words[1].confidence) - (0.8)) <= (0.001))
    }

    @Test
    func testMakeWordsMergesContinuationTokensAndAveragesConfidence() {
        let words = ParakeetTranscriber.makeWords(
            sourceID: sourceID,
            tokenTimings: tokens([
                ("▁при", 0.0, 0.25, 0.6),
                ("вет", 0.3, 0.6, 0.7),
            ]),
            fallbackConfidence: 0.0)

        #expect(words.count == 1)
        #expect(words[0].text == "привет")
        // Слово охватывает первый и последний сабвурд-токены.
        #expect(words[0].start == 0.0)
        #expect(words[0].end == 0.6)
        #expect(abs((words[0].confidence) - (0.65)) <= (0.001))
    }

    @Test
    func testMakeWordsSkipsBlankTokens() {
        let words = ParakeetTranscriber.makeWords(
            sourceID: sourceID,
            tokenTimings: tokens([
                ("<blank>", 0.0, 0.1, 0.5),
                ("▁ок", 0.1, 0.2, 1.0),
            ]),
            fallbackConfidence: 0.0)

        #expect(words.count == 1)
        #expect(words[0].text == "ок")
        #expect(abs((words[0].confidence) - (1.0)) <= (0.001))
    }

    @Test
    func testMakeWordsReturnsEmptyForEmptyTokens() {
        #expect(ParakeetTranscriber.makeWords(sourceID: sourceID, tokenTimings: [], fallbackConfidence: 0.0).isEmpty)
    }
}
