@preconcurrency import AVFoundation
import Foundation
import Testing

@testable import MontazhkaKit

@Suite("Shorts draft factory")
struct ShortsDraftFactoryTests {
    private let media = MediaReference(path: "/tmp/talk.mov")

    /// Слова по полсекунды с паузой 0.1 с; после слова `longGapAfter` — пауза 1 с.
    private func words(_ count: Int, longGapAfter: Int? = nil, texts: [String]? = nil) -> [TranscriptWord] {
        var time = 1.0
        return (0..<count).map { index in
            let word = TranscriptWord(
                sourceID: media.id, text: texts?[index] ?? "слово\(index + 1)", start: time, end: time + 0.5,
                confidence: 1)
            time += index + 1 == longGapAfter ? 1.5 : 0.6
            return word
        }
    }

    private func draft(
        _ pieces: [ShortsDraftFactory.Piece], words: [TranscriptWord], trimPauses: Bool = false,
        peaks: [Float] = [], removeFillers: Bool = false
    ) throws -> [Clip] {
        let clips = [Clip(source: media, start: 0, end: 100)]
        let map = TranscriptTimelineMapper.make(clips: clips, transcripts: words).words
        return try ShortsDraftFactory.clips(
            for: pieces, map: map, clips: clips, peaksFor: { _ in peaks }, sourceDuration: { _ in 100 },
            thresholdDB: -40, trimPauses: trimPauses, removeFillers: removeFillers)
    }

    @Test("a word range becomes a clip around those words")
    func wordRangeClip() throws {
        let spoken = words(10)
        let clips = try draft([ShortsDraftFactory.Piece(from: 3, to: 5)], words: spoken)
        #expect(clips.count == 1)
        #expect(clips[0].start <= spoken[2].start && clips[0].start > spoken[1].end - 0.2)
        #expect(clips[0].end >= spoken[4].end && clips[0].end < spoken[5].start + 0.2)
    }

    @Test("pieces keep the order the agent gave, even backwards")
    func piecesOrder() throws {
        let spoken = words(20)
        let clips = try draft(
            [ShortsDraftFactory.Piece(from: 15, to: 17), ShortsDraftFactory.Piece(from: 2, to: 4)], words: spoken)
        #expect(clips.count == 2)
        #expect(clips[0].start > clips[1].start)
    }

    @Test("word numbers outside the transcript fail loudly")
    func badNumbers() {
        #expect(throws: ShortsDraftError.self) {
            try draft([ShortsDraftFactory.Piece(from: 5, to: 50)], words: words(10))
        }
    }

    @Test("a seconds piece works without a transcript")
    func secondsPiece() throws {
        let clips = try draft([ShortsDraftFactory.Piece(start: 10, end: 25)], words: [])
        #expect(clips.count == 1)
        #expect(abs(clips[0].start - 10) < 1e-9 && abs(clips[0].end - 25) < 1e-9)
    }

    @Test("a short hum between words is cut when fillers are removed")
    func removesHum() throws {
        let spoken = words(6, longGapAfter: 3)
        // Громко всё время: между словами 3 и 4 звучит «эээ» (1 с без слов).
        let loud = [Float](repeating: 0.3, count: 100 * 100)
        let clips = [Clip(source: media, start: 0, end: 100)]
        let map = TranscriptTimelineMapper.make(clips: clips, transcripts: spoken).words
        let result = try ShortsDraftFactory.clips(
            for: [ShortsDraftFactory.Piece(from: 1, to: 6)], map: map, clips: clips, peaksFor: { _ in loud },
            sourceDuration: { _ in 100 }, thresholdDB: -40, trimPauses: false, removeFillers: true)
        #expect(result.count == 2)
        #expect(result[0].end <= spoken[2].end + 0.15)
        #expect(result[1].start >= spoken[3].start - 0.15)
    }

    @Test("a hum takes the dead air around it too, and no word-less blips remain")
    func humGapIsCleared() throws {
        // «наоборот» — долгая тишина — короткий звук «эээ» — снова тишина — «Но».
        let tail = (0..<24).map { index in
            TranscriptWord(
                sourceID: media.id, text: "дальше", start: 7.0 + Double(index) * 0.6,
                end: 7.5 + Double(index) * 0.6, confidence: 1)
        }
        let spoken = [
            TranscriptWord(sourceID: media.id, text: "наоборот.", start: 1.0, end: 1.8, confidence: 1),
            TranscriptWord(sourceID: media.id, text: "Но", start: 6.3, end: 6.6, confidence: 1),
        ] + tail
        let peaks = (0..<2500).map { index -> Float in
            let time = Double(index) / 100
            let silent = (time >= 1.8 && time < 4.4) || (time >= 5.0 && time < 6.3)
            return silent ? 0.0005 : 0.3
        }
        let clips = try draft(
            [ShortsDraftFactory.Piece(from: 1, to: spoken.count)], words: spoken, trimPauses: true, peaks: peaks,
            removeFillers: true)
        let gap = clips.filter { $0.end > 1.8 && $0.start < 6.3 }
        #expect(gap.allSatisfy { $0.start <= 1.8 || $0.start >= 6.1 }, "в промежутке без слов не должно остаться кусков: \(clips.map { ($0.start, $0.end) })")
        #expect(clips.allSatisfy { $0.duration >= 0.3 })
    }

    @Test("a pause cut never slices a word as the transcript sees it")
    func cutsKeepWordsWhole() throws {
        // Длинный кусок: паузы режутся, только если ролик остаётся длиннее 12 секунд.
        let tail = (0..<24).map { index in
            TranscriptWord(
                sourceID: media.id, text: "дальше", start: 2.6 + Double(index) * 0.6,
                end: 3.1 + Double(index) * 0.6, confidence: 1)
        }
        let spoken = [
            TranscriptWord(sourceID: media.id, text: "скажу", start: 1.0, end: 1.5, confidence: 1),
            TranscriptWord(sourceID: media.id, text: "возможно", start: 2.0, end: 2.5, confidence: 1),
        ] + tail
        // Слово «возможно» звучит позже, чем его отметило распознавание: тишина до 2.15 с.
        let peaks = (0..<2000).map { index -> Float in
            let time = Double(index) / 100
            return time >= 1.5 && time < 2.15 ? 0.0005 : 0.3
        }
        let clips = try draft(
            [ShortsDraftFactory.Piece(from: 1, to: spoken.count)], words: spoken, trimPauses: true, peaks: peaks)
        let draftMap = TranscriptTimelineMapper.make(clips: clips, transcripts: spoken).words
        #expect(clips.count == 2, "пауза 1.5–2.15 должна вырезаться")
        #expect(draftMap.prefix(2).map(\.text) == ["скажу", "возможно"])
    }

    @Test("a pause inside one word is not cut, so nothing plays twice")
    func noCutInsideWord() throws {
        let tail = (0..<24).map { index in
            TranscriptWord(
                sourceID: media.id, text: "дальше", start: 2.6 + Double(index) * 0.6,
                end: 3.1 + Double(index) * 0.6, confidence: 1)
        }
        // Распознавание растянуло «возможно» на тишину 1.5–2.15 с внутри слова.
        let spoken = [
            TranscriptWord(sourceID: media.id, text: "скажу", start: 1.0, end: 1.5, confidence: 1),
            TranscriptWord(sourceID: media.id, text: "возможно", start: 1.55, end: 2.5, confidence: 1),
        ] + tail
        let peaks = (0..<2000).map { index -> Float in
            let time = Double(index) / 100
            return time >= 1.5 && time < 2.15 ? 0.0005 : 0.3
        }
        let clips = try draft(
            [ShortsDraftFactory.Piece(from: 1, to: spoken.count)], words: spoken, trimPauses: true, peaks: peaks)
        for (a, b) in zip(clips, clips.dropFirst()) {
            #expect(b.start >= a.end, "куски \(a.start)–\(a.end) и \(b.start)–\(b.end) перекрываются")
        }
        let texts = TranscriptTimelineMapper.make(clips: clips, transcripts: spoken).words.map(\.text)
        #expect(texts.filter { $0 == "возможно" }.count == 1)
    }

    @Test("a softly spoken word inside a long pause stays, the dead air around it goes")
    func softWordIsKept() throws {
        let tail = (0..<24).map { index in
            TranscriptWord(
                sourceID: media.id, text: "дальше", start: 6.8 + Double(index) * 0.6,
                end: 7.3 + Double(index) * 0.6, confidence: 1)
        }
        let spoken = [
            TranscriptWord(sourceID: media.id, text: "наоборот.", start: 1.0, end: 1.8, confidence: 1),
            TranscriptWord(sourceID: media.id, text: "Но", start: 6.3, end: 6.6, confidence: 1),
        ] + tail
        // «Но» сказано тихо: по громкости оно неотличимо от тишины 1.8–6.8 с.
        let peaks = (0..<2500).map { index -> Float in
            let time = Double(index) / 100
            return time >= 1.8 && time < 6.8 ? 0.0005 : 0.3
        }
        let clips = try draft(
            [ShortsDraftFactory.Piece(from: 1, to: spoken.count)], words: spoken, trimPauses: true, peaks: peaks)
        let texts = TranscriptTimelineMapper.make(clips: clips, transcripts: spoken).words.map(\.text)
        #expect(texts.prefix(2) == ["наоборот.", "Но"])
        #expect(!clips.contains { $0.start < 4 && $0.end > 4 }, "мёртвый воздух 2–6 с должен вырезаться: \(clips.map { ($0.start, $0.end) })")
    }

    @Test("a piece over several project clips never brings back what the user cut")
    func respectsProjectCuts() throws {
        // Пользователь вырезал оговорку 5.0–5.4: в проекте два клипа подряд по исходнику.
        let project = [Clip(source: media, start: 0, end: 5.0), Clip(source: media, start: 5.4, end: 12)]
        let spoken = [
            TranscriptWord(sourceID: media.id, text: "раз", start: 4.0, end: 4.9, confidence: 1),
            TranscriptWord(sourceID: media.id, text: "оговорка", start: 5.0, end: 5.4, confidence: 1),
            TranscriptWord(sourceID: media.id, text: "два", start: 5.45, end: 6.0, confidence: 1),
        ]
        let map = TranscriptTimelineMapper.make(clips: project, transcripts: spoken).words
        #expect(map.map(\.text) == ["раз", "два"])
        let clips = try ShortsDraftFactory.clips(
            for: [ShortsDraftFactory.Piece(from: 1, to: 2)], map: map, clips: project, peaksFor: { _ in [] },
            sourceDuration: { _ in 12 }, thresholdDB: -40, trimPauses: false, removeFillers: false)
        #expect(!clips.contains { $0.start < 5.4 && $0.end > 5.0 }, "вырезанное вернулось: \(clips.map { ($0.start, $0.end) })")
        for (a, b) in zip(clips, clips.dropFirst()) { #expect(b.start >= a.end) }
    }

    @Test("zooms are pinned to source time of the chosen words")
    func zoomSpans() throws {
        let spoken = words(10)
        let clips = [Clip(source: media, start: 0, end: 100)]
        let map = TranscriptTimelineMapper.make(clips: clips, transcripts: spoken).words
        let zooms = try ShortsDraftFactory.zooms([AgentWordRange(from: 4, to: 6)], map: map)
        #expect(zooms.count == 1)
        #expect(zooms[0].sourceStart == spoken[3].start && zooms[0].sourceEnd == spoken[5].end)
        #expect(zooms[0].sourceID == media.id)
    }

    @Test("auto zooms land on whole sentences after the hook")
    func autoZooms() {
        let texts = ["Смотрите.", "Это", "самый", "важный", "момент", "всего", "ролика!", "А", "дальше", "всё."]
        let spoken = words(10, texts: texts)
        let clips = [Clip(source: media, start: 0, end: 100)]
        let map = TranscriptTimelineMapper.make(clips: clips, transcripts: spoken).words
        let zooms = ShortsDraftFactory.autoZooms(map: map, total: 30, notBefore: 0.5)
        #expect(zooms.count == 1)
        #expect(zooms.first?.sourceStart == spoken[1].start)
        #expect(zooms.first?.sourceEnd == spoken[6].end)
    }

    @Test("music follows the mood, or stays off when asked")
    func musicChoice() {
        let energetic = ShortsDraftFactory.music(track: nil, mood: "energetic", variant: 0)
        #expect(energetic.enabled && energetic.ducking)
        #expect(MusicLibrary.track(id: energetic.trackID ?? "")?.mood == "energetic")
        #expect(!ShortsDraftFactory.music(track: "none", mood: nil, variant: 0).enabled)
    }
}
