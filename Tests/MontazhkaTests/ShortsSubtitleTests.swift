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
            words: words, timeMap: .single(start: 0.15, end: 1.35))

        #expect((cues.map(\.text)) == (["Один два три четыре", "пять"]))
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
            words: words, timeMap: .single(start: 0, end: 2))

        #expect((cues.map(\.text)) == (["Первая фраза", "Вторая мысль"]))
        #expect(cues.count == 2)
    }

    @Test
    func emptyOrReversedRangeProducesNoCues() {
        let word = word("текст", start: 0, end: 1, sourceID: UUID())

        #expect(
            ShortsSubtitleCueBuilder.make(
                words: [word], timeMap: .single(start: 2, end: 1)
            ).isEmpty)
        #expect(
            ShortsSubtitleCueBuilder.make(
                words: [word], timeMap: .single(start: 3, end: 4)
            ).isEmpty)
    }

    @Test
    func presetFillsAppearanceAndManualEditLeavesIt() {
        var appearance = ShortsSubtitlePreset.plate.appearance

        #expect(appearance.preset == .plate)
        #expect(appearance.background == .plate)

        appearance.textColor = .coral
        #expect(appearance.preset == nil)

        appearance = ShortsSubtitlePreset.outline.appearance
        #expect(appearance.preset == .outline)
    }

    @Test
    func missingFontFallsBackToSystemOne() {
        for font in ShortsSubtitleFont.allCases {
            let resolved = font.font(ofSize: 24)
            #expect(resolved.pointSize == 24)
            #expect(!resolved.fontName.isEmpty)
        }
    }

    @Test
    func longPhraseShrinksInsteadOfSpillingOverTwoLines() {
        let canvas = CGSize(width: 1080, height: 1920)
        let appearance = ShortsSubtitlePreset.classic.appearance
        let phrase = "Совершенно невероятная длинная фраза"

        let font = ShortsSubtitleLayout.fittingFont(
            text: phrase, appearance: appearance, canvasSize: canvas)
        let layout = ShortsSubtitleTextWrapper.wrap(
            phrase,
            font: font,
            maxWidth: ShortsSubtitleLayout.textWidth(
                fontSize: font.pointSize, canvasSize: canvas))

        #expect(layout.lineCount <= ShortsSubtitleLayout.maxLines)
        #expect(font.pointSize <= appearance.baseFontSize(canvasSize: canvas))
    }

    @Test
    func positionRaisesTextInVerticalFrame() {
        let vertical = CGSize(width: 1080, height: 1920)
        var appearance = ShortsSubtitlePreset.classic.appearance

        appearance.position = .low
        let low = ShortsSubtitleLayout.bottomMargin(appearance: appearance, canvasSize: vertical)
        appearance.position = .high
        let high = ShortsSubtitleLayout.bottomMargin(appearance: appearance, canvasSize: vertical)

        #expect(high > low)
        // Даже нижнее положение не прижимает подпись к краю кадра.
        #expect(low >= vertical.height * 0.06)
    }

    @Test
    func subtitleModeCarriesWordsOnlyWhenEnabled() {
        let words = [word("Текст", start: 0, end: 1, sourceID: UUID())]

        #expect(ShortsSubtitleSettings.default.mode(with: words) == .off)

        let appearance = ShortsSubtitlePreset.accent.appearance
        let settings = ShortsSubtitleSettings(
            enabled: true, appearance: appearance, highlightActiveWord: true)
        #expect(
            settings.mode(with: words)
                == .on(words: words, appearance: appearance, highlight: true))
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

    @Test
    func cutBoundaryAlwaysEndsTheCue() {
        let sourceID = UUID()
        let words = [
            word("Один", start: 0.0, end: 0.2, sourceID: sourceID),
            word("два", start: 0.25, end: 0.45, sourceID: sourceID),
            word("три", start: 1.0, end: 1.2, sourceID: sourceID),
        ]
        // Пауза 0.5–1.0 вырезана: «три» приезжает вплотную к «два», но склейка
        // посреди строки субтитров выглядела бы сломанной.
        let map = ShortsTimeMap(segments: [
            ShortsSegment(start: 0, end: 0.5), ShortsSegment(start: 1.0, end: 1.5),
        ])

        let cues = ShortsSubtitleCueBuilder.make(words: words, timeMap: map)

        #expect((cues.map(\.text)) == (["Один два", "три"]))
        #expect(abs((cues.last?.start ?? 0) - 0.5) < 0.001)
    }

    @Test
    func wordsSwallowedByACutDisappearWithIt() {
        let sourceID = UUID()
        let words = [
            word("Слышно", start: 0.0, end: 0.3, sourceID: sourceID),
            word("вырезано", start: 0.7, end: 0.9, sourceID: sourceID),
            word("снова", start: 1.2, end: 1.4, sourceID: sourceID),
        ]
        let map = ShortsTimeMap(segments: [
            ShortsSegment(start: 0, end: 0.5), ShortsSegment(start: 1.1, end: 1.5),
        ])

        let cues = ShortsSubtitleCueBuilder.make(words: words, timeMap: map)

        #expect((cues.flatMap { $0.words.map(\.text) }) == (["Слышно", "снова"]))
    }

    @Test
    func activeWordFollowsTheSpokenTiming() {
        let cue = ShortsSubtitleCue(
            words: [
                ShortsSubtitleWord(text: "Раз", start: 0, end: 0.4),
                ShortsSubtitleWord(text: "два", start: 0.4, end: 0.9),
            ],
            start: 0, end: 0.9)

        #expect(cue.activeWordIndex(at: 0.1) == 0)
        #expect(cue.activeWordIndex(at: 0.5) == 1)
        #expect(cue.activeWordIndex(at: 1.5) == nil)
        #expect(cue.text == "Раз два")
    }

    @Test
    func wrappingReportsWhereEveryWordLanded() {
        let font = NSFont.systemFont(ofSize: 54, weight: .bold)
        let text = "Автоматические субтитры должны сохранять весь текст"
        let layout = ShortsSubtitleTextWrapper.wrap(text, font: font, maxWidth: 600)
        let words = text.split(separator: " ").map(String.init)

        #expect(layout.placements.count == words.count)
        #expect(layout.lineWidths.count == layout.lineCount)
        // Каждое слово знает свою строку, стоит внутри её ширины и не нулевое.
        for placement in layout.placements {
            #expect(placement.line < layout.lineCount)
            #expect(placement.width > 0)
            #expect(placement.x + placement.width <= layout.lineWidths[placement.line] + 1)
        }
        // Слова одной строки идут слева направо, без наложений.
        for line in 0..<layout.lineCount {
            let inLine = layout.placements.filter { $0.line == line }
            let sorted = inLine.sorted { $0.x < $1.x }
            #expect((inLine.map(\.x)) == (sorted.map(\.x)))
        }
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
