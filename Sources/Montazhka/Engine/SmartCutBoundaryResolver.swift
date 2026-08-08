import Foundation

struct SmartCutBoundary: Equatable, Sendable {
    let timelineStart: Double
    let timelineEnd: Double
}

enum SmartCutBoundaryResolver {
    private static let windowsPerSecond = WaveformStore.windowsPerSecond
    private static let minimumQuietWindows = 3
    private static let searchRadius = 0.30
    private static let desiredAir = 0.06

    static func resolve(words: ArraySlice<MappedTranscriptWord>,
                        clip: Clip,
                        clipTimelineStart: Double,
                        peaks: [Float],
                        projectThresholdDB: Double) -> SmartCutBoundary? {
        guard let first = words.first, let last = words.last,
              first.clipID == clip.id, last.clipID == clip.id else { return nil }

        let projectThreshold = Float(pow(10, projectThresholdDB / 20))
        let localStart = max(clip.start, first.sourceStart - 1)
        let localEnd = min(clip.end, last.sourceEnd + 1)
        let localPeaks = peakSlice(peaks, from: localStart, to: localEnd)
        let noiseFloor = percentile(localPeaks, fraction: 0.20)
        let threshold = max(projectThreshold, min(0.035, noiseFloor * 1.8))

        let leftTarget = max(clip.start, first.sourceStart - desiredAir)
        let rightTarget = min(clip.end, last.sourceEnd + desiredAir)
        guard let sourceStart = quietPoint(near: leftTarget, in: peaks, threshold: threshold,
                                           lower: max(clip.start, first.sourceStart - searchRadius),
                                           upper: first.sourceStart, preferLatest: true),
              let sourceEnd = quietPoint(near: rightTarget, in: peaks, threshold: threshold,
                                         lower: last.sourceEnd,
                                         upper: min(clip.end, last.sourceEnd + searchRadius),
                                         preferLatest: false) else { return nil }

        let timelineStart = clipTimelineStart + sourceStart - clip.start
        let timelineEnd = clipTimelineStart + sourceEnd - clip.start
        guard timelineEnd - timelineStart >= 0.25 else { return nil }
        return SmartCutBoundary(timelineStart: timelineStart, timelineEnd: timelineEnd)
    }

    private static func quietPoint(near target: Double, in peaks: [Float], threshold: Float,
                                   lower: Double, upper: Double, preferLatest: Bool) -> Double? {
        guard !peaks.isEmpty, upper > lower else { return nil }
        let first = max(0, Int((lower * windowsPerSecond).rounded(.up)))
        let last = min(peaks.count - minimumQuietWindows,
                       Int((upper * windowsPerSecond).rounded(.down)))
        guard first <= last else { return nil }
        let candidates = (first...last).filter { index in
            peaks[index..<(index + minimumQuietWindows)].allSatisfy { $0 <= threshold }
        }
        guard !candidates.isEmpty else { return nil }
        let targetIndex = Int(target * windowsPerSecond)
        let chosen = candidates.min { lhs, rhs in
            let ld = abs(lhs - targetIndex)
            let rd = abs(rhs - targetIndex)
            if ld == rd { return preferLatest ? lhs > rhs : lhs < rhs }
            return ld < rd
        }!
        return Double(chosen) / windowsPerSecond
    }

    private static func peakSlice(_ peaks: [Float], from: Double, to: Double) -> [Float] {
        guard !peaks.isEmpty else { return [] }
        let first = max(0, min(peaks.count, Int(from * windowsPerSecond)))
        let last = max(first, min(peaks.count, Int(to * windowsPerSecond)))
        return Array(peaks[first..<last])
    }

    private static func percentile(_ values: [Float], fraction: Double) -> Float {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let index = min(sorted.count - 1, max(0, Int(Double(sorted.count - 1) * fraction)))
        return sorted[index]
    }
}
