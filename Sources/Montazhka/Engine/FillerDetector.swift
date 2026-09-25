import Foundation

/// «Эээ», «ммм» и прочие звуки без слов. Распознавание их не записывает,
/// поэтому ищем по звуку: между соседними словами голос есть, а слов нет.
enum FillerDetector {
    /// Короче — щелчок или вдох, не филлер.
    static let minDuration = 0.25
    /// Длиннее — скорее пропущенная распознаванием фраза: только отмечаем.
    static let maxFillerDuration = 1.5
    /// Слова обрамляем запасом, чтобы не принять их хвосты за филлер.
    private static let wordMargin = 0.05

    /// Звучащий кусок внутри паузы между словами `from…to` (секунды исходника).
    /// `peaks` — пики громкости исходника, `WaveformStore.windowsPerSecond` в секунду.
    static func voicedSpan(from: Double, to: Double, peaks: [Float], thresholdDB: Double) -> ClosedRange<Double>? {
        let rate = WaveformStore.windowsPerSecond
        let first = max(0, Int(((from + wordMargin) * rate).rounded(.up)))
        let last = min(peaks.count, Int(((to - wordMargin) * rate).rounded(.down)))
        guard last > first else { return nil }
        let threshold = Float(pow(10, thresholdDB / 20))
        let voiced = (first..<last).filter { peaks[$0] > threshold }
        guard let start = voiced.first, let end = voiced.last else { return nil }
        let span = Double(end + 1 - start) / rate
        guard span >= minDuration, Double(voiced.count) >= Double(end + 1 - start) * 0.5 else { return nil }
        return (Double(start) / rate)...(Double(end + 1) / rate)
    }

    static func isLikelyFiller(_ span: ClosedRange<Double>) -> Bool {
        span.upperBound - span.lowerBound <= maxFillerDuration
    }
}
