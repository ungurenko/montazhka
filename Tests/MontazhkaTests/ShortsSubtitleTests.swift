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

    /// Слепок фраз шортса: правила для горизонтальных роликов не должны сдвинуть
    /// в них ни слова, ни миллисекунды. Времена — двоичные дроби, поэтому
    /// сравнение точное.
    @Test
    func shortsCuesFromSourceWordsStayExactlyAsBefore() {
        let sourceID = UUID()
        let words = [
            word("Привет,", start: 0.0, end: 0.25, sourceID: sourceID),
            word("это", start: 0.375, end: 0.5, sourceID: sourceID),
            // Точка в шортсе фразу не рвёт.
            word("тест.", start: 0.625, end: 0.875, sourceID: sourceID),
            word("Длинное", start: 1.0, end: 1.25, sourceID: sourceID),
            // Пятое слово — уже новая фраза.
            word("слово", start: 1.375, end: 1.5, sourceID: sourceID),
            word("   ", start: 1.5625, end: 1.625, sourceID: sourceID),
            // Больше 30 знаков вместе с «слово».
            word("абвгдеёжзийклмнопрстуфхцч", start: 1.75, end: 2.0, sourceID: sourceID),
            // Пауза 0.625 — новая фраза.
            word("пауза", start: 2.625, end: 2.75, sourceID: sourceID),
            // Не по порядку во входе: сортировка ставит на место.
            word("два", start: 3.5, end: 3.75, sourceID: sourceID),
            word("раз", start: 3.0, end: 3.25, sourceID: sourceID),
            // Фраза длиннее 1.85 с — новая.
            word("три", start: 4.25, end: 4.5, sourceID: sourceID),
            word("вырезано", start: 5.25, end: 5.5, sourceID: sourceID),
            // На стыке, большей частью во втором куске — склейка рвёт фразу.
            word("стык", start: 5.875, end: 6.25, sourceID: sourceID),
            word("ок", start: 6.875, end: 6.9375, sourceID: sourceID),
            word("конец", start: 7.5, end: 7.75, sourceID: sourceID),
            word("после", start: 9.5, end: 9.75, sourceID: sourceID),
        ]
        let map = ShortsTimeMap(segments: [
            ShortsSegment(start: 0, end: 5), ShortsSegment(start: 6, end: 9),
        ])

        let cues = ShortsSubtitleCueBuilder.make(words: words, timeMap: map)

        #expect(
            cues == [
                pinned(
                    [("Привет,", 0, 0.25), ("это", 0.375, 0.5), ("тест.", 0.625, 0.875), ("Длинное", 1.0, 1.25)],
                    end: 1.25),
                pinned([("слово", 1.375, 1.5)], end: 1.5),
                pinned([("абвгдеёжзийклмнопрстуфхцч", 1.75, 2.0)], end: 2.0),
                pinned([("пауза", 2.625, 2.75), ("раз", 3.0, 3.25), ("два", 3.5, 3.75)], end: 3.75),
                pinned([("три", 4.25, 4.5)], end: 4.5),
                pinned([("стык", 5.0, 5.25)], end: 5.25),
                pinned([("ок", 5.875, 5.9375)], end: 5.875 + 0.12),
                pinned([("конец", 6.5, 6.75)], end: 6.75),
            ])
    }

    /// Тот же слепок для черновика шортса, где слова уже разложены по ленте.
    @Test
    func shortsCuesFromTimelineWordsStayExactlyAsBefore() {
        let clipA = UUID()
        let clipB = UUID()
        let words = [
            mapped("до хука", 0.25, 0.375, clip: clipA),
            mapped("Раз,", 0.5, 0.75, clip: clipA),
            mapped("два.", 0.875, 1.0, clip: clipA),
            mapped(" ", 1.0625, 1.125, clip: clipA),
            mapped("четыре", 1.375, 1.5, clip: clipA),
            mapped("три", 1.125, 1.25, clip: clipA),
            mapped("пять", 1.625, 1.75, clip: clipA),
            mapped("шесть", 1.875, 2.0, clip: clipB),
            mapped("семь", 2.125, 2.25, clip: clipB),
            mapped("пусто", 2.5, 2.5, clip: clipB),
            mapped("восемь", 3.0, 3.0625, clip: clipB),
        ]

        let cues = ShortsSubtitleCueBuilder.make(mapped: words, notBefore: 0.5)

        #expect(
            cues == [
                pinned(
                    [("Раз,", 0.5, 0.75), ("два.", 0.875, 1.0), ("три", 1.125, 1.25), ("четыре", 1.375, 1.5)],
                    end: 1.5),
                pinned([("пять", 1.625, 1.75)], end: 1.75),
                pinned([("шесть", 1.875, 2.0), ("семь", 2.125, 2.25)], end: 2.25),
                pinned([("восемь", 3.0, 3.0625)], end: 3.0 + 0.12),
            ])
    }

    /// Вертикальный и квадратный кадр: ширина текста и кегль те же, что были
    /// до горизонтальной раскладки.
    @Test
    func verticalAndSquareGeometryStaysAsBefore() {
        let appearance = ShortsSubtitlePreset.classic.appearance
        for canvas in [CGSize(width: 1080, height: 1920), CGSize(width: 1080, height: 1080)] {
            #expect(appearance.baseFontSize(canvasSize: canvas) == max(14, 1080 * 0.060))
            let width = ShortsSubtitleLayout.textWidth(fontSize: 54, canvasSize: canvas)
            #expect(abs(width - (1080 * 0.86 - 54 * 0.45 * 2)) < 1e-9)
        }
        let vertical = CGSize(width: 1080, height: 1920)
        let font = ShortsSubtitleLayout.fittingFont(
            text: "Привет", appearance: appearance, canvasSize: vertical)
        #expect(font.pointSize == 1080 * 0.060)
    }

    @Test
    func horizontalFrameUsesNarrowerLineAndSmallerType() {
        let horizontal = CGSize(width: 1920, height: 1080)
        let vertical = CGSize(width: 1080, height: 1920)
        let appearance = ShortsSubtitlePreset.classic.appearance

        #expect(ShortsSubtitleLayout.widthRatio(for: horizontal) == 0.72)
        #expect(ShortsSubtitleLayout.widthRatio(for: vertical) == 0.86)
        #expect(ShortsSubtitleLayout.widthRatio(for: CGSize(width: 1080, height: 1080)) == 0.86)
        #expect(abs(appearance.baseFontSize(canvasSize: horizontal) - 1080 * 0.060 * 0.8) < 1e-9)
        let width = ShortsSubtitleLayout.textWidth(fontSize: 54, canvasSize: horizontal)
        #expect(abs(width - (1920 * 0.72 - 54 * 0.45 * 2)) < 1e-9)

        // Рамка запечённой фразы берёт ту же долю ширины, что и текст.
        let cue = ShortsSubtitleCue(words: [ShortsSubtitleWord(text: "Привет", start: 0, end: 1)], start: 0, end: 1)
        for canvas in [horizontal, vertical] {
            let layer = ShortsSubtitleRenderer.overlayLayer(
                renderSize: canvas, cues: [cue], appearance: appearance, highlight: false, duration: 2, hook: nil)
            let frame = layer.sublayers?.first?.frame ?? .zero
            #expect(abs(frame.width - canvas.width * ShortsSubtitleLayout.widthRatio(for: canvas)) < 1e-9)
            #expect(abs(frame.midX - canvas.width / 2) < 1e-9)
        }
    }

    @Test
    func horizontalCueEndsWithTheSentence() {
        let clip = UUID()
        let texts = ["Это", "первое", "предложение.", "А", "это", "второе!", "Правда?", "Ну…", "  ", "конец"]
        let words = texts.enumerated().map { index, text in
            mapped(text, Double(index) * 0.3, Double(index) * 0.3 + 0.25, clip: clip)
        }

        let cues = ShortsSubtitleCueBuilder.make(mapped: words, rules: .horizontal)

        #expect(cues.map(\.text) == ["Это первое предложение.", "А это второе!", "Правда?", "Ну…", "конец"])
    }

    @Test
    func horizontalCueBreaksAtACommaOnlyWhenAlreadyLong() {
        let clip = UUID()
        func cues(_ texts: [String]) -> [String] {
            let words = texts.enumerated().map { index, text in
                mapped(text, Double(index) * 0.3, Double(index) * 0.3 + 0.25, clip: clip)
            }
            return ShortsSubtitleCueBuilder.make(mapped: words, rules: .horizontal).map(\.text)
        }

        #expect(cues(["Сначала,", "коротко", "и", "дальше"]) == ["Сначала, коротко и дальше"])
        #expect(
            cues(["Когда", "мы", "монтируем", "длинное", "видео", "для", "канала", "на", "ютубе,", "субтитры", "нужны"])
                == ["Когда мы монтируем длинное видео для канала на ютубе,", "субтитры нужны"])
    }

    @Test
    func horizontalCueHoldsAtMostEightyFourCharacters() {
        let clip = UUID()
        let words = (0..<20).map { index in
            mapped("слово", Double(index) * 0.3, Double(index) * 0.3 + 0.25, clip: clip)
        }

        let cues = ShortsSubtitleCueBuilder.make(mapped: words, rules: .horizontal)

        // 14 слов по 5 букв с пробелами — 83 знака; пятнадцатое уже не влезает.
        #expect(cues.map(\.words.count) == [14, 6])
        #expect(cues.allSatisfy { $0.text.count <= 84 })
    }

    @Test
    func horizontalCueBreaksAtClipChangeAndLongPause() {
        let clipA = UUID()
        let clipB = UUID()
        let words = [
            mapped("раз", 0.0, 0.25, clip: clipA),
            // Пауза 0.7 — для горизонтального ролика ещё не повод рвать фразу.
            mapped("два", 0.95, 1.2, clip: clipA),
            mapped("три", 1.3, 1.55, clip: clipB),
            // Пауза 0.9 — новая фраза.
            mapped("четыре", 2.45, 2.7, clip: clipB),
        ]

        let cues = ShortsSubtitleCueBuilder.make(mapped: words, rules: .horizontal)

        #expect(cues.map(\.text) == ["раз два", "три", "четыре"])
    }

    @Test
    func shortHorizontalCueStaysLongerButNeverRunsIntoTheNextOne() {
        let clip = UUID()
        let words = [
            mapped("Да.", 0.0, 0.25, clip: clip),
            mapped("Нет.", 0.5, 0.75, clip: clip),
            mapped("Хорошо,", 3.0, 3.25, clip: clip),
            mapped("договорились", 3.3, 4.5, clip: clip),
        ]

        let cues = ShortsSubtitleCueBuilder.make(mapped: words, rules: .horizontal)

        #expect(cues.map(\.text) == ["Да.", "Нет.", "Хорошо, договорились"])
        #expect(cues.map(\.start) == [0.0, 0.5, 3.0])
        // «Да.» дотягивается только до «Нет.», «Нет.» — на полную секунду,
        // длинная фраза не меняется. Слова внутри фразы не трогаются.
        #expect(cues.map(\.end) == [0.5, 1.5, 4.5])
        #expect(cues[0].words[0].end == 0.25)
    }

    @Test
    func horizontalCuesSkipWordsBeforeNotBefore() {
        let clip = UUID()
        let words = [
            mapped("хук", 0.5, 1.0, clip: clip),
            mapped("ещё", 1.5, 1.9, clip: clip),
            mapped("речь", 2.0, 2.5, clip: clip),
        ]

        let cues = ShortsSubtitleCueBuilder.make(mapped: words, notBefore: 2.0, rules: .horizontal)

        #expect(cues.map(\.text) == ["речь"])
    }

    private func pinned(_ words: [(String, Double, Double)], end: Double) -> ShortsSubtitleCue {
        ShortsSubtitleCue(
            words: words.map { ShortsSubtitleWord(text: $0.0, start: $0.1, end: $0.2) },
            start: words[0].1, end: end)
    }

    private func mapped(_ text: String, _ start: Double, _ end: Double, clip: UUID) -> MappedTranscriptWord {
        MappedTranscriptWord(
            wordID: UUID().uuidString, text: text, clipID: clip, sourceID: UUID(),
            sourceStart: start, sourceEnd: end, timelineStart: start, timelineEnd: end, confidence: 1)
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
