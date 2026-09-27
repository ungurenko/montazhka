import Foundation
import Testing

@testable import MontazhkaKit

@Suite("Retake hints")
struct RetakeFinderTests {
    private let clip = UUID()
    private let source = UUID()

    private func word(_ text: String, _ start: Double, _ end: Double, clip: UUID? = nil) -> MappedTranscriptWord {
        MappedTranscriptWord(
            wordID: "w", text: text, clipID: clip ?? self.clip, sourceID: source,
            sourceStart: start, sourceEnd: end, timelineStart: start, timelineEnd: end, confidence: 1)
    }

    /// Фразы подряд: слово длится 0.3 с, между словами 0.1 с, перед фразой — своя пауза.
    private func script(_ phrases: [(text: String, pauseBefore: Double)]) -> [MappedTranscriptWord] {
        var result: [MappedTranscriptWord] = []
        var lastEnd = 0.0
        for (index, phrase) in phrases.enumerated() {
            for (offset, token) in phrase.text.split(separator: " ").enumerated() {
                let start = result.isEmpty ? 0 : lastEnd + (offset == 0 && index > 0 ? phrase.pauseBefore : 0.1)
                result.append(word(String(token), start, start + 0.3))
                lastEnd = start + 0.3
            }
        }
        return result
    }

    private func retakes(_ phrases: [String]) -> [RetakeGroup] {
        retakes(phrases.map { ($0, 1.0) })
    }

    private func retakes(_ phrases: [(text: String, pauseBefore: Double)]) -> [RetakeGroup] {
        let words = script(phrases)
        return RetakeFinder.retakes(RetakeFinder.phrases(words), words: words)
    }

    @Test("a pause of 0.5 s or more and a cut start a new phrase, a shorter pause does not")
    func phraseSplitting() {
        let other = UUID()
        let words = [
            word("Раз,", 0.0, 0.3), word("два", 0.7, 1.0),
            word("три.", 1.5, 1.8),
            word("Четыре", 1.9, 2.2, clip: other), word("пять", 2.3, 2.6, clip: other),
        ]
        #expect(
            RetakeFinder.phrases(words) == [
                TranscriptPhrase(index: 0, firstWord: 0, lastWord: 1, start: 0.0, end: 1.0, text: "Раз, два"),
                TranscriptPhrase(index: 1, firstWord: 2, lastWord: 2, start: 1.5, end: 1.8, text: "три."),
                TranscriptPhrase(index: 2, firstWord: 3, lastWord: 4, start: 1.9, end: 2.6, text: "Четыре пять"),
            ])
    }

    @Test("empty fixWords tails never form a phrase or a token but stay inside their phrase")
    func emptyTailsIgnored() {
        let words = [
            word("", 0.0, 0.2),
            word("Сегодня", 1.0, 1.3), word("открываем", 1.4, 1.7), word("Claude Code", 1.8, 2.1),
            word("", 2.1, 2.4),
            word("", 3.4, 3.6),
            word("Сегодня", 4.0, 4.3), word("открываем", 4.4, 4.7), word("Claude Code", 4.8, 5.1),
            word("", 5.1, 5.4),
        ]
        let phrases = RetakeFinder.phrases(words)
        #expect(
            phrases == [
                TranscriptPhrase(
                    index: 0, firstWord: 1, lastWord: 4, start: 1.0, end: 2.4,
                    text: "Сегодня открываем Claude Code"),
                TranscriptPhrase(
                    index: 1, firstWord: 6, lastWord: 9, start: 4.0, end: 5.4,
                    text: "Сегодня открываем Claude Code"),
            ])
        #expect(
            RetakeFinder.retakes(phrases, words: words) == [RetakeGroup(phrases: [0, 1], similarity: 1, kind: .repeat)])
    }

    @Test("repeat and restart scores follow the matching rules")
    func similarityScores() {
        let sameWithOtherEnding = RetakeFinder.similarity(
            ["давайте", "сделаем", "нарезку"], ["давайте", "сделаю", "нарезку"])
        #expect(sameWithOtherEnding.score == 1)
        #expect(sameWithOtherEnding.kind == .repeat)

        let falseStart = RetakeFinder.similarity(["сегодня", "мы"], ["сегодня", "мы", "поговорим"])
        #expect(falseStart.score == 1)
        #expect(falseStart.kind == .restart)

        // Короткие слова совпадают только целиком: «он» ≠ «она».
        #expect(RetakeFinder.similarity(["он", "ты", "мы"], ["она", "ты", "мы"]).score == 2.0 * 2 / 6)
        #expect(RetakeFinder.similarity(["да", "да"], ["да", "да"]).score == 0)
        #expect(RetakeFinder.similarity(["да"], ["да"]).score == 0)
    }

    @Test("a false start followed by the full phrase is a restart")
    func falseStartIsRestart() {
        #expect(
            retakes(["Сегодня мы поговорим", "Сегодня мы поговорим о монтаже видео"]) == [
                RetakeGroup(phrases: [0, 1], similarity: 1, kind: .restart)
            ])
    }

    @Test("the same phrase with different word endings is a repeat")
    func differentEndingsAreRepeat() {
        #expect(
            retakes(["Давайте сделаем нарезку для канала", "Давайте сделаю нарезку для канала"]) == [
                RetakeGroup(phrases: [0, 1], similarity: 1, kind: .repeat)
            ])
    }

    @Test("unrelated neighbours and takes beyond lookahead or maxSpan are not grouped")
    func distantTakesNotGrouped() {
        let take = "покажу как обрезать видео быстро"
        let fillers = ["а теперь про звук", "микрофон стоит близко", "свет тоже важен", "камера на штативе"]

        #expect(retakes(["Привет всем кто смотрит", "Сегодня поговорим про звук"]).isEmpty)
        #expect(retakes([take] + fillers + [take]).isEmpty)
        #expect(
            retakes([take] + fillers.prefix(3) + [take]) == [
                RetakeGroup(phrases: [0, 4], similarity: 1, kind: .repeat)
            ])
        #expect(retakes([(take, 1), (take, 30.5)]).isEmpty)
        #expect(retakes([(take, 1), (take, 29.5)]).count == 1)
    }

    @Test("three takes chain into one group with the weakest link as its similarity")
    func chainOfThreeTakes() throws {
        let short = "покажу как обрезать видео быстро"
        let full = "покажу как обрезать видео очень быстро"
        let groups = retakes([
            short, "а теперь про звук", "микрофон стоит близко",
            full, "свет тоже важен", "камера на штативе",
            full,
        ])
        let group = try #require(groups.first)
        #expect(groups.count == 1)
        #expect(group.phrases == [0, 3, 6])
        #expect(abs(group.similarity - 10.0 / 11.0) < 1e-9)
        #expect(group.kind == .repeat)
    }

    @Test("short identical words like «да, да» are never a retake")
    func yesYesIgnored() {
        #expect(retakes(["Да, да.", "Да, да.", "Да."]).isEmpty)
    }

    @Test("at most maxGroups groups, earliest first")
    func groupLimit() {
        let pairs = (0..<60).flatMap { index -> [String] in
            let sentence = "\(index * 3) \(index * 3 + 1) \(index * 3 + 2)"
            return [sentence, sentence]
        }
        let groups = retakes(pairs)
        #expect(groups.count == RetakeFinder.maxGroups)
        #expect(groups.first?.phrases == [0, 1])
        #expect(groups.last?.phrases == [98, 99])
    }
}
