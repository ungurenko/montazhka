import Foundation
import Testing

@testable import MontazhkaKit

@Suite
struct SubRipWriterTests {
    @Test
    func numbersCuesAndSeparatesThemWithABlankLine() {
        let cues = [
            cue(["Привет,", "мир."], start: 0, end: 1.5),
            cue(
                ["Сегодня", "разберём", "монтаж", "длинных", "роликов", "без", "лишних", "пауз"],
                start: 61.25, end: 64.5),
        ]

        #expect(
            SubRipWriter.text(cues: cues)
                == """
                1
                00:00:00,000 --> 00:00:01,500
                Привет, мир.

                2
                00:01:01,250 --> 00:01:04,500
                Сегодня разберём монтаж
                длинных роликов без лишних пауз

                """)
    }

    @Test
    func timestampsRoundToTheNearestMillisecond() {
        let text = SubRipWriter.text(cues: [
            cue(["раз"], start: 59.9994, end: 3599.9996),
            cue(["два"], start: 3723.004, end: 36000),
        ])
        let timings = text.split(separator: "\n").filter { $0.contains("-->") }

        #expect(
            timings == [
                "00:00:59,999 --> 01:00:00,000",
                "01:02:03,004 --> 10:00:00,000",
            ])
    }

    @Test
    func longCueWrapsIntoAtMostTwoLines() {
        func lines(_ words: [String]) -> [String] {
            let text = SubRipWriter.text(cues: [cue(words, start: 0, end: 1)])
            return Array(text.split(separator: "\n").dropFirst(2).map(String.init))
        }

        #expect(lines(["Короткая", "фраза"]) == ["Короткая фраза"])
        // 95 знаков: двумя ровными строками по 42 не уложить — первая берёт
        // сколько влезает, вторая остаток.
        let tooLong = Array(repeating: "слово", count: 16)
        #expect(
            lines(tooLong) == [
                Array(repeating: "слово", count: 7).joined(separator: " "),
                Array(repeating: "слово", count: 9).joined(separator: " "),
            ])
        // Одно слово длиннее строки не рвётся.
        let longWord = String(repeating: "а", count: 50)
        #expect(lines([longWord]) == [longWord])
    }

    @Test
    func subtitlesSitNextToTheVideoUnderTheSameName() {
        #expect(
            SubRipWriter.url(forVideo: URL(fileURLWithPath: "/tmp/Монтаж/ролик.v2.mp4"))
                == URL(fileURLWithPath: "/tmp/Монтаж/ролик.v2.srt"))
        #expect(
            SubRipWriter.url(forVideo: URL(fileURLWithPath: "/tmp/Монтаж/video"))
                == URL(fileURLWithPath: "/tmp/Монтаж/video.srt"))
    }

    private func cue(_ words: [String], start: Double, end: Double) -> ShortsSubtitleCue {
        ShortsSubtitleCue(
            words: words.map { ShortsSubtitleWord(text: $0, start: start, end: end) },
            start: start, end: end)
    }
}
