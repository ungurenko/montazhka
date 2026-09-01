import Foundation
import Testing

@testable import MontazhkaKit

@Suite
struct ShortsSegmentTests {
    // MARK: - Поиск кусков речи

    @Test
    func cutsLongPausesAndKeepsSpeech() {
        // 30 секунд речи с двумя паузами: 5.0–6.5 и 20.0–21.0.
        let peaks = makePeaks(duration: 30, silences: [(5.0, 6.5), (20.0, 21.0)])
        let segments = ShortsSegmentPlanner.segments(
            start: 0, end: 30, peaks: peaks, thresholdDB: -40)

        #expect(segments.count == 3)
        // Отступ «воздуха» 120 мс с каждой стороны сохраняет дыхание перед фразой.
        #expect(abs(segments[0].end - 5.12) < 0.02)
        #expect(abs(segments[1].start - 6.38) < 0.02)
        #expect(abs(segments[2].start - 20.88) < 0.02)
        #expect(abs(segments[2].end - 30) < 0.001)
    }

    @Test
    func shortPauseSurvivesUntouched() {
        // 0.3 секунды тишины — короче порога 0.45, режем нечего.
        let peaks = makePeaks(duration: 20, silences: [(8.0, 8.3)])
        let segments = ShortsSegmentPlanner.segments(
            start: 0, end: 20, peaks: peaks, thresholdDB: -40)

        #expect(segments == [ShortsSegment(start: 0, end: 20)])
    }

    @Test
    func roomlessRangeStaysWhole() {
        // Ролик на 14 секунд почти весь молчит: вырезать столько нельзя,
        // иначе он станет короче осмысленного минимума.
        let peaks = makePeaks(duration: 14, silences: [(1.0, 13.0)])
        let segments = ShortsSegmentPlanner.segments(
            start: 0, end: 14, peaks: peaks, thresholdDB: -40)

        #expect(segments == [ShortsSegment(start: 0, end: 14)])
    }

    @Test
    func emptyWaveformKeepsRangeWhole() {
        let segments = ShortsSegmentPlanner.segments(
            start: 3, end: 25, peaks: [], thresholdDB: -40)

        #expect(segments == [ShortsSegment(start: 3, end: 25)])
    }

    @Test
    func deadAirAtTheStartIsDroppedInsteadOfBecomingATinyPiece() {
        // Ролик начинается с двух секунд тишины: отдельным куском это дало бы
        // мигание на первом же кадре, поэтому начало просто сдвигается.
        let peaks = makePeaks(duration: 30, silences: [(0.0, 2.0)])
        let segments = ShortsSegmentPlanner.segments(
            start: 0, end: 30, peaks: peaks, thresholdDB: -40)

        #expect(segments.count == 1)
        #expect(abs((segments.first?.start ?? 0) - 1.88) < 0.02)
        #expect((segments.map(\.duration).filter { $0 < ShortsLimits.minSegmentDuration }) == ([]))
    }

    // MARK: - Карта времени

    @Test
    func timeMapIsLinearInsideSegmentsAndBlankInsideCuts() {
        let map = ShortsTimeMap(segments: [
            ShortsSegment(start: 10, end: 15),
            ShortsSegment(start: 20, end: 23),
        ])

        #expect(map.outputDuration == 8)
        #expect(map.removedDuration == 5)
        #expect(map.outputTime(forSource: 10) == 0)
        #expect(map.outputTime(forSource: 12.5) == 2.5)
        #expect(map.outputTime(forSource: 20) == 5)
        #expect(map.outputTime(forSource: 22) == 7)
        #expect(map.outputTime(forSource: 17) == nil)
        #expect(map.outputTime(forSource: 30) == nil)
    }

    @Test
    func continuousMapKeepsEverything() {
        let map = ShortsTimeMap.single(start: 4, end: 34)

        #expect(map.isContinuous)
        #expect(map.outputDuration == 30)
        #expect(map.removedDuration == 0)
        #expect(map.outputTime(forSource: 4) == 0)
        #expect(map.outputTime(forSource: 34) == 30)
    }

    @Test
    func wordOnACutIsShownWhereItIsHeardLonger() {
        let map = ShortsTimeMap(segments: [
            ShortsSegment(start: 0, end: 10),
            ShortsSegment(start: 12, end: 20),
        ])

        // Слово 9.8–13.0: в первом куске 0.2 с, во втором — 1.0 с.
        let piece = map.longestVisiblePiece(from: 9.8, to: 13.0)
        #expect(piece?.start == 12)
        #expect(piece?.end == 13)
        #expect(map.longestVisiblePiece(from: 10.2, to: 11.5) == nil)
    }

    @Test
    func candidateFallsBackToOneContinuousPieceWhenTrimmingIsOff() {
        let candidate = ShortCandidate(
            id: UUID(), rank: 1, title: "Тест", reason: "", hook: "", pattern: "",
            excerpt: "", start: 5, end: 35, confidence: 1,
            hookScore: 8, standaloneScore: 8, payoffScore: 8, pacingScore: 8,
            segments: [ShortsSegment(start: 5, end: 20), ShortsSegment(start: 22, end: 35)],
            enabled: true)

        #expect(candidate.timeMap(trimmingPauses: false) == .single(start: 5, end: 35))
        #expect(candidate.timeMap(trimmingPauses: true).outputDuration == 28)
    }

    /// Тихо там, где сказано; всюду ещё — уверенно громко.
    private func makePeaks(duration: Double, silences: [(Double, Double)]) -> [Float] {
        let wps = WaveformStore.windowsPerSecond
        return (0..<Int(duration * wps)).map { index in
            let time = Double(index) / wps
            let quiet = silences.contains { time >= $0.0 && time < $0.1 }
            return quiet ? 0.0001 : 0.5
        }
    }
}
