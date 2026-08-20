import Foundation

/// Границы ролика: старт на тихой точке до первого слова, конец — на тихой
/// точке после последнего, чтобы фраза не обрывалась на полуслове. Если тишину
/// найти не удалось, отступаем фиксированный «воздух» — кандидат не должен
/// теряться из-за шумного фона.
enum ShortsBoundaryResolver {
    struct Boundary: Equatable, Sendable {
        let start: Double
        let end: Double
        var duration: Double { max(0, end - start) }
    }

    private static let startAir = 0.20
    private static let endAir = 0.35
    private static let startRadius = 0.60
    private static let endRadius = 0.90
    private static let windowsPerSecond = WaveformStore.windowsPerSecond

    static func resolve(
        first: MappedTranscriptWord,
        last: MappedTranscriptWord,
        peaks: [Float],
        sourceDuration: Double,
        thresholdDB: Double
    ) -> Boundary? {
        guard last.sourceEnd > first.sourceStart else { return nil }

        let start = resolveStart(firstWord: first, peaks: peaks, thresholdDB: thresholdDB)
        let end = resolveEnd(
            lastWord: last, peaks: peaks, sourceDuration: sourceDuration,
            thresholdDB: thresholdDB)
        guard end > start, end - start >= 0.5 else { return nil }
        return Boundary(start: start, end: end)
    }

    private static func resolveStart(
        firstWord: MappedTranscriptWord,
        peaks: [Float], thresholdDB: Double
    ) -> Double {
        let fallback = max(0, firstWord.sourceStart - 0.10)
        guard !peaks.isEmpty else { return fallback }
        let target = max(0, firstWord.sourceStart - startAir)
        let quiet = quietPoint(
            near: target,
            peaks: peaks, thresholdDB: thresholdDB,
            lower: max(0, firstWord.sourceStart - startRadius),
            upper: firstWord.sourceStart,
            preferLatest: true)
        return quiet ?? fallback
    }

    private static func resolveEnd(
        lastWord: MappedTranscriptWord,
        peaks: [Float], sourceDuration: Double,
        thresholdDB: Double
    ) -> Double {
        let fallback = min(sourceDuration, lastWord.sourceEnd + 0.15)
        guard !peaks.isEmpty else { return fallback }
        let target = min(sourceDuration, lastWord.sourceEnd + endAir)
        let quiet = quietPoint(
            near: target,
            peaks: peaks, thresholdDB: thresholdDB,
            lower: lastWord.sourceEnd,
            upper: min(sourceDuration, lastWord.sourceEnd + endRadius),
            preferLatest: false)
        return quiet ?? fallback
    }

    /// Повторяет подход склеек: порог — максимум из проектного (по умолчанию)
    /// и локального уровня шума вокруг фрагмента.
    private static func quietPoint(
        near target: Double, peaks: [Float],
        thresholdDB: Double, lower: Double, upper: Double,
        preferLatest: Bool
    ) -> Double? {
        let window = peakSlice(peaks, from: lower, to: upper)
        let noiseFloor = SmartCutBoundaryResolver.percentile(window, fraction: 0.20)
        let projectThreshold = Float(pow(10, thresholdDB / 20))
        let threshold = max(projectThreshold, min(0.035, noiseFloor * 1.8))
        return SmartCutBoundaryResolver.quietPoint(
            near: target, in: peaks, threshold: threshold,
            lower: lower, upper: upper,
            preferLatest: preferLatest)
    }

    private static func peakSlice(_ peaks: [Float], from: Double, to: Double) -> [Float] {
        guard !peaks.isEmpty else { return [] }
        let first = max(0, min(peaks.count, Int((from * windowsPerSecond).rounded())))
        let last = max(first, min(peaks.count, Int((to * windowsPerSecond).rounded())))
        return Array(peaks[first..<last])
    }
}
