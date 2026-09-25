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
    /// Совсем короткие вырезки не имеют смысла.
    static let minimumCut = 0.15
    /// Сколько тишины оставлять у слова, если пауза его задевает.
    static let wordAir = 0.04

    /// Паузы ищутся по громкости, и тихое слово (шёпот, затухающий конец фразы)
    /// может попасть внутрь «тишины». Если расшифровка есть, вырезку сужаем
    /// или делим так, чтобы слова остались целыми. Времена — секунды ленты.
    static func sparingWords(
        _ pauses: [PauseCandidate], words: [(start: Double, end: Double)]
    ) -> [PauseCandidate] {
        pauses.flatMap { pause -> [PauseCandidate] in
            var pieces = [(from: pause.start, to: pause.end)]
            for word in words where word.end > pause.start && word.start < pause.end {
                let keepFrom = word.start - wordAir
                let keepTo = word.end + wordAir
                pieces = pieces.flatMap { piece -> [(from: Double, to: Double)] in
                    guard keepTo > piece.from, keepFrom < piece.to else { return [piece] }
                    return [(piece.from, min(piece.to, keepFrom)), (max(piece.from, keepTo), piece.to)]
                        .filter { $0.to - $0.from >= minimumCut }
                }
            }
            return pieces.map { piece in
                var result = pause
                result.start = piece.from
                result.end = piece.to
                return result
            }
        }
    }

    /// Ищет тихие участки внутри каждого клипа по заранее посчитанным пикам
    /// громкости. Результат — в секундах ленты.
    static func findPauses(
        clips: [Clip],
        peaksFor: (String) -> [Float]?,
        settings: DetectionSettings
    ) -> [PauseCandidate] {
        var result: [PauseCandidate] = []
        var timelineOffset = 0.0

        for clip in clips {
            if Task.isCancelled { return [] }
            defer { timelineOffset += clip.duration }
            guard let peaks = peaksFor(clip.sourcePath), !peaks.isEmpty else { continue }

            let offset = timelineOffset - clip.start
            for pause in pauses(in: peaks, from: clip.start, to: clip.end, settings: settings) {
                var moved = pause
                moved.start += offset
                moved.end += offset
                moved.fullStart += offset
                moved.fullEnd += offset
                result.append(moved)
            }
        }
        return result
    }

    /// Тихие участки внутри одного диапазона исходника. Все времена — секунды
    /// исходника. Чистая функция: её переиспользует нарезка shorts, где нет
    /// ленты и клипов.
    static func pauses(
        in peaks: [Float],
        from: Double,
        to: Double,
        settings: DetectionSettings
    ) -> [PauseCandidate] {
        let wps = WaveformStore.windowsPerSecond
        let threshold = Float(pow(10.0, settings.thresholdDB / 20.0))
        let padding = settings.paddingMS / 1000.0
        let minCut = minimumCut

        let first = max(0, Int(from * wps))
        let last = min(peaks.count, Int(to * wps))
        guard first < last else { return [] }

        var result: [PauseCandidate] = []
        var runStart: Int? = nil
        for i in first...last {
            let silent = i < last && peaks[i] < threshold
            if silent && runStart == nil { runStart = i }
            if !silent, let rs = runStart {
                runStart = nil
                let runFrom = Double(rs) / wps
                let runTo = Double(i) / wps
                guard runTo - runFrom >= settings.minPauseDuration else { continue }

                let cutFrom = runFrom + padding
                let cutTo = runTo - padding
                guard cutTo - cutFrom >= minCut else { continue }

                result.append(
                    PauseCandidate(
                        start: cutFrom, end: cutTo,
                        fullStart: runFrom, fullEnd: runTo))
            }
        }
        return result
    }
}
