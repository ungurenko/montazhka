import AppKit
import Foundation
import Testing

@testable import MontazhkaKit

@Suite
struct ShortsSubtitleTests {
    @Test
    func groupsWordsByReadableLengthAndKeepsRelativeTiming() {
        let sourceID = UUID()
        let words = [
            word("Один", start: 0.0, end: 0.2, sourceID: sourceID),
            word("два", start: 0.3, end: 0.5, sourceID: sourceID),
            word("три", start: 0.6, end: 0.8, sourceID: sourceID),
            word("четыре", start: 0.9, end: 1.1, sourceID: sourceID),
            word("пять", start: 1.2, end: 1.4, sourceID: sourceID),
        ]

        let cues = ShortsSubtitleCueBuilder.make(
            words: words,
            sourceStart: 0.15,
            sourceEnd: 1.35,
            relativeTo: 0.15)

        #expect(cues.map(\.text) == ["Один два три четыре", "пять"])
        #expect(cues[0].start == 0)
        #expect(abs(cues[0].end - 0.95) < 0.001)
        #expect(abs(cues[1].start - 1.05) < 0.001)
        #expect(abs(cues[1].end - 1.20) < 0.001)
    }

    @Test
    func startsNewCueAfterSpeechGapAndIgnoresEmptyWords() {
        let sourceID = UUID()
        let words = [
            word("Первая", start: 0.0, end: 0.25, sourceID: sourceID),
            word("фраза", start: 0.3, end: 0.6, sourceID: sourceID),
            word(" ", start: 0.7, end: 0.8, sourceID: sourceID),
            word("Вторая", start: 1.2, end: 1.45, sourceID: sourceID),
            word("мысль", start: 1.5, end: 1.8, sourceID: sourceID),
        ]

        let cues = ShortsSubtitleCueBuilder.make(
            words: words,
            sourceStart: 0,
            sourceEnd: 2,
            relativeTo: 0)

        #expect(cues.map(\.text) == ["Первая фраза", "Вторая мысль"])
        #expect(cues.count == 2)
    }

    @Test
    func emptyOrReversedRangeProducesNoCues() {
        let word = word("текст", start: 0, end: 1, sourceID: UUID())

        #expect(
            ShortsSubtitleCueBuilder.make(
                words: [word], sourceStart: 2, sourceEnd: 1, relativeTo: 0
            ).isEmpty)
        #expect(
            ShortsSubtitleCueBuilder.make(
                words: [word], sourceStart: 1, sourceEnd: 2, relativeTo: 1
            ).isEmpty)
    }

    @Test
    func subtitleModeCarriesWordsOnlyWhenEnabled() {
        let words = [word("Текст", start: 0, end: 1, sourceID: UUID())]

        #expect(ShortsSubtitleSettings.default.mode(with: words) == .off)

        let settings = ShortsSubtitleSettings(enabled: true, style: .accent, size: .large)
        #expect(
            settings.mode(with: words)
                == .on(words: words, style: .accent, size: .large))
        #expect(settings.mode(with: []) == .off)
    }

    @Test
    func longCaptionWrapsWithoutDroppingCharacters() {
        let text = "Автоматические субтитры должны сохранять весь текст"
        let layout = ShortsSubtitleTextWrapper.wrap(
            text,
            font: NSFont.systemFont(ofSize: 54, weight: .bold),
            maxWidth: 600)

        #expect(layout.lineCount > 1)
        #expect(layout.text.replacingOccurrences(of: "\n", with: " ") == text)
    }

    private func word(
        _ text: String,
        start: Double,
        end: Double,
        sourceID: UUID
    ) -> TranscriptWord {
        TranscriptWord(sourceID: sourceID, text: text, start: start, end: end, confidence: 1)
    }
}
