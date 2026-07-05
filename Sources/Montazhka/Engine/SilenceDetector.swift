import Foundation

/// Найденная пауза. Все времена — в секундах ленты (таймлайна).
struct PauseCandidate: Identifiable, Equatable {
    let id = UUID()
    /// Границы вырезаемого куска (уже с отступами «воздуха»).
    var start: Double
    var end: Double
    /// Полные границы тихого участка — для подсветки на ленте.
    var fullStart: Double
    var fullEnd: Double
    var enabled = true

    var duration: Double { end - start }
}

enum SilenceDetector {
    /// Ищет тихие участки внутри каждого клипа по заранее посчитанным пикам громкости.
    static func findPauses(clips: [Clip],
                           peaksFor: (String) -> [Float]?,
                           settings: DetectionSettings) -> [PauseCandidate] {
        let wps = WaveformStore.windowsPerSecond
        let threshold = Float(pow(10.0, settings.thresholdDB / 20.0))
        let padding = settings.paddingMS / 1000.0
        let minCut = 0.15 // совсем короткие вырезки не имеют смысла

        var result: [PauseCandidate] = []
        var timelineOffset = 0.0

        for clip in clips {
            defer { timelineOffset += clip.duration }
            guard let peaks = peaksFor(clip.sourcePath), !peaks.isEmpty else { continue }

            let first = max(0, Int(clip.start * wps))
            let last = min(peaks.count, Int(clip.end * wps))
            guard first < last else { continue }

            var runStart: Int? = nil
            for i in first...last {
                let silent = i < last && peaks[i] < threshold
                if silent && runStart == nil { runStart = i }
                if !silent, let rs = runStart {
                    runStart = nil
                    let runFrom = Double(rs) / wps           // секунды исходника
                    let runTo = Double(i) / wps
                    guard runTo - runFrom >= settings.minPauseDuration else { continue }

                    let cutFrom = runFrom + padding
                    let cutTo = runTo - padding
                    guard cutTo - cutFrom >= minCut else { continue }

                    let toTimeline = { (src: Double) in timelineOffset + (src - clip.start) }
                    result.append(PauseCandidate(start: toTimeline(cutFrom),
                                                 end: toTimeline(cutTo),
                                                 fullStart: toTimeline(runFrom),
                                                 fullEnd: toTimeline(runTo)))
                }
            }
        }
        return result
    }
}
