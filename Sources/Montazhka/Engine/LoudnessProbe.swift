import Foundation

/// Громкость отрезка ленты «глазами агента»: средний уровень по равным отрезкам
/// и тихие участки. Все времена — секунды ленты.
struct LoudnessReport: Equatable, Sendable {
    struct Silence: Equatable, Sendable {
        let from: Double
        let to: Double
    }

    let from: Double
    let to: Double
    let bucketSeconds: Double
    /// Уровень каждого отрезка в dBFS (−100 — полная тишина или нет данных).
    let levelsDB: [Double]
    let loudestDB: Double
    let silences: [Silence]
}

enum LoudnessProbe {
    static let floorDB = -100.0

    static func measure(
        clips: [Clip], peaksFor: (String) -> [Float]?,
        from: Double, to: Double, buckets: Int,
        settings: DetectionSettings = DetectionSettings()
    ) -> LoudnessReport {
        let total = clips.reduce(0) { $0 + $1.duration }
        let lower = min(max(0, from), total)
        let upper = min(max(lower, to), total)
        // Отрезок не короче одного окна волны (10 мс), иначе часть отрезков пустая.
        let windows = Int(((upper - lower) * WaveformStore.windowsPerSecond).rounded(.down))
        let count = max(1, min(200, buckets, windows))
        let bucketSeconds = max(0.01, (upper - lower) / Double(count))
        var energy = [Double](repeating: 0, count: count)
        var samples = [Int](repeating: 0, count: count)
        var loudest: Float = 0

        let wps = WaveformStore.windowsPerSecond
        var offset = 0.0
        for clip in clips {
            defer { offset += clip.duration }
            let visibleFrom = max(lower, offset)
            let visibleTo = min(upper, offset + clip.duration)
            guard visibleFrom < visibleTo, let peaks = peaksFor(clip.sourcePath) else { continue }
            let first = max(0, Int((clip.start + visibleFrom - offset) * wps))
            let last = min(peaks.count, Int((clip.start + visibleTo - offset) * wps))
            guard first < last else { continue }
            for window in first..<last {
                let timeline = offset + Double(window) / wps - clip.start
                let bucket = min(count - 1, max(0, Int((timeline - lower) / bucketSeconds)))
                let value = peaks[window]
                energy[bucket] += Double(value * value)
                samples[bucket] += 1
                loudest = max(loudest, value)
            }
        }

        let levels = zip(energy, samples).map { sum, n in
            n == 0 ? floorDB : decibels(Float(sqrt(sum / Double(n))))
        }
        let silences = SilenceDetector.findPauses(clips: clips, peaksFor: peaksFor, settings: settings)
            .filter { $0.fullEnd > lower && $0.fullStart < upper }
            .map { LoudnessReport.Silence(from: max(lower, $0.fullStart), to: min(upper, $0.fullEnd)) }
        return LoudnessReport(
            from: lower, to: upper, bucketSeconds: bucketSeconds,
            levelsDB: levels, loudestDB: decibels(loudest), silences: silences)
    }

    private static func decibels(_ value: Float) -> Double {
        guard value > 0 else { return floorDB }
        return max(floorDB, (20 * log10(Double(value)) * 10).rounded() / 10)
    }
}
