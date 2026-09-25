import Foundation
import Testing

@testable import MontazhkaKit

@Suite("Agent word edits and search")
struct AgentWordEditTests {
    private let source = MediaReference(path: "/tmp/words.mov")

    /// Громкость по окнам 10 мс: слова громкие, промежутки тихие.
    private func peaks(loud: [(Double, Double)], seconds: Double = 10) -> [Float] {
        let count = Int(seconds * WaveformStore.windowsPerSecond)
        return (0..<count).map { index in
            let time = Double(index) / WaveformStore.windowsPerSecond
            return loud.contains { time >= $0.0 && time < $0.1 } ? 0.5 : 0.001
        }
    }

    private func word(_ text: String, _ start: Double, _ end: Double) -> TranscriptWord {
        TranscriptWord(sourceID: source.id, text: text, start: start, end: end, confidence: 1)
    }

    @Test("search ignores case, ё and punctuation and matches word beginnings")
    func searchNormalizes() {
        let words = ["Привет,", "это", "ЁЖИК", "в", "тумане.", "Ёжик", "снова"]
        #expect(TranscriptSearch.matches(of: "ежик в туман", in: words) == [2...4])
        #expect(TranscriptSearch.matches(of: "ёжик", in: words) == [2...2, 5...5])
        #expect(TranscriptSearch.matches(of: "  ", in: words).isEmpty)
        #expect(TranscriptSearch.matches(of: "слона", in: words).isEmpty)
    }

    @Test("deleteWords cuts in the silence around the chosen words")
    func wordCutLandsInSilence() throws {
        let clip = Clip(source: source, start: 0, end: 10)
        let words = [word("раз", 1.0, 1.4), word("два", 1.8, 2.2), word("три", 2.6, 3.0)]
        let map = TranscriptTimelineMapper.make(clips: [clip], transcripts: words)
        let loud = peaks(loud: [(1.0, 1.4), (1.8, 2.2), (2.6, 3.0)])

        let ranges = try AgentWordCuts.timelineRanges(
            [AgentWordRange(from: 2, to: 2)], map: map, clips: [clip],
            peaksFor: { _ in loud }, thresholdDB: -40)

        let cut = try #require(ranges.first)
        #expect(ranges.count == 1)
        #expect(cut.inSilence)
        #expect(cut.words == 2...2)
        #expect(cut.range.from >= 1.4 && cut.range.from <= 1.8)
        #expect(cut.range.to >= 2.2 && cut.range.to <= 2.6)
    }

    @Test("deleteWords without a quiet point keeps the neighbours whole")
    func wordCutFallback() throws {
        let clip = Clip(source: source, start: 0, end: 10)
        let words = [word("раз", 1.0, 1.4), word("два", 1.45, 1.8), word("три", 1.85, 2.2)]
        let map = TranscriptTimelineMapper.make(clips: [clip], transcripts: words)
        let noisy = [Float](repeating: 0.5, count: 1000)

        let cut = try #require(
            AgentWordCuts.timelineRanges(
                [AgentWordRange(from: 2, to: 2)], map: map, clips: [clip],
                peaksFor: { _ in noisy }, thresholdDB: -40
            ).first)

        #expect(!cut.inSilence)
        #expect(cut.range.from >= 1.4 && cut.range.from <= 1.45)
        #expect(cut.range.to >= 1.8 && cut.range.to <= 1.85)
    }

    @Test("a word range across a splice becomes one cut per clip")
    func wordCutAcrossSplice() throws {
        let clips = [Clip(source: source, start: 0, end: 2), Clip(source: source, start: 5, end: 8)]
        let words = [word("раз", 1.0, 1.4), word("два", 5.4, 5.8), word("три", 6.4, 6.8)]
        let map = TranscriptTimelineMapper.make(clips: clips, transcripts: words)
        let loud = peaks(loud: [(1.0, 1.4), (5.4, 5.8), (6.4, 6.8)])

        let ranges = try AgentWordCuts.timelineRanges(
            [AgentWordRange(from: 1, to: 2)], map: map, clips: clips,
            peaksFor: { _ in loud }, thresholdDB: -40)

        #expect(ranges.map(\.words) == [1...1, 2...2])
        #expect(ranges[0].range.to <= 2)
        #expect(ranges[1].range.from >= 2)
    }

    @Test("word numbers outside the transcript are refused")
    func wordCutRejectsUnknownNumbers() {
        let clip = Clip(source: source, start: 0, end: 10)
        let map = TranscriptTimelineMapper.make(clips: [clip], transcripts: [word("раз", 1, 1.4)])
        #expect(throws: AgentServiceError.self) {
            try AgentWordCuts.timelineRanges(
                [AgentWordRange(from: 1, to: 3)], map: map, clips: [clip],
                peaksFor: { _ in nil }, thresholdDB: -40)
        }
    }

    @Test("the timeline fingerprint changes after any edit")
    func fingerprintTracksEdits() throws {
        let clips = [Clip(source: source, start: 0, end: 10)]
        let edited = try TimelineEditOps.apply(
            [.delete(ranges: [TimelineRange(from: 2, to: 3)])], to: clips, sourceDurations: [:])
        #expect(AgentWordCuts.fingerprint(clips) == AgentWordCuts.fingerprint(clips))
        #expect(AgentWordCuts.fingerprint(clips) != AgentWordCuts.fingerprint(edited))
    }

    @Test("pause removal spares quiet words inside the silence")
    func pausesSpareWords() {
        let pause = PauseCandidate(start: 1, end: 3, fullStart: 0.9, fullEnd: 3.1)
        let split = SilenceDetector.sparingWords([pause], words: [(start: 1.9, end: 2.1)])
        #expect(split.count == 2)
        #expect(abs(split[0].start - 1) < 0.001 && abs(split[0].end - 1.86) < 0.001)
        #expect(abs(split[1].start - 2.14) < 0.001 && abs(split[1].end - 3) < 0.001)

        let shrunk = SilenceDetector.sparingWords([pause], words: [(start: 0.5, end: 1.2)])
        #expect(shrunk.count == 1 && abs(shrunk[0].start - 1.24) < 0.001)

        let untouched = SilenceDetector.sparingWords([pause], words: [(start: 3.5, end: 4)])
        #expect(untouched == [pause])
    }

    @Test("new clips shorter than a quarter second are reported as fragments")
    func fragmentWarnings() {
        let kept = Clip(source: source, start: 0, end: 0.1)
        let fresh = Clip(source: source, start: 2, end: 2.1)
        let long = Clip(source: source, start: 3, end: 5)
        let warnings = AgentService.fragmentWarnings([kept, fresh, long], previousIDs: [kept.id])
        #expect(warnings.count == 1)
        #expect(warnings.first?.hasPrefix("Клип 1 ") == true)
    }
}
