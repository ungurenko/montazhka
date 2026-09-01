import Foundation

/// Кусок исходника, попадающий в готовый ролик. Секунды исходника.
struct ShortsSegment: Equatable, Sendable, Codable {
    let start: Double
    let end: Double

    var duration: Double { max(0, end - start) }
}

/// Кусочно-линейное соответствие «время исходника → время готового ролика».
/// После вырезания пауз эти шкалы расходятся, и через карту проходят все, кому
/// нужно попасть в одну точку: экспорт, предпросмотр и субтитры.
struct ShortsTimeMap: Equatable, Sendable {
    let segments: [ShortsSegment]

    init(segments: [ShortsSegment]) {
        self.segments = segments.filter { $0.duration > 0 }
    }

    static func single(start: Double, end: Double) -> ShortsTimeMap {
        ShortsTimeMap(segments: [ShortsSegment(start: start, end: end)])
    }

    var outputDuration: Double { segments.reduce(0) { $0 + $1.duration } }
    var sourceStart: Double { segments.first?.start ?? 0 }
    var sourceEnd: Double { segments.last?.end ?? 0 }
    /// Сколько секунд паузы вырезано: для подписи «0:45 → 0:38».
    var removedDuration: Double { max(0, (sourceEnd - sourceStart) - outputDuration) }
    var isContinuous: Bool { segments.count <= 1 }

    /// Время в готовом ролике. nil — момент попал в вырезанную паузу.
    func outputTime(forSource time: Double) -> Double? {
        var offset = 0.0
        for segment in segments {
            if time >= segment.start, time <= segment.end {
                return offset + (time - segment.start)
            }
            offset += segment.duration
        }
        return nil
    }

    /// Пересечение отрезка исходника с сегментом, где он виден дольше всего.
    /// Слово на стыке склейки показывается один раз, по большей части.
    func longestVisiblePiece(from: Double, to: Double) -> (start: Double, end: Double)? {
        var best: (start: Double, end: Double)?
        for segment in segments {
            let start = max(from, segment.start)
            let end = min(to, segment.end)
            guard end > start else { continue }
            if best == nil || end - start > best!.end - best!.start {
                best = (start, end)
            }
        }
        return best
    }
}

/// Делит диапазон ролика на куски речи, выбрасывая паузы между ними.
/// Чистая логика поверх готовых пиков громкости — проверяется без AVFoundation.
enum ShortsSegmentPlanner {
    static func segments(
        start: Double,
        end: Double,
        peaks: [Float],
        thresholdDB: Double
    ) -> [ShortsSegment] {
        let whole = [ShortsSegment(start: start, end: end)]
        let duration = end - start
        guard duration > 0, !peaks.isEmpty else { return whole }

        let settings = DetectionSettings(
            thresholdDB: thresholdDB,
            minPauseDuration: ShortsLimits.minPauseDuration,
            paddingMS: ShortsLimits.pausePaddingMS)
        let found = SilenceDetector.pauses(
            in: peaks, from: start, to: end, settings: settings
        )
        .map { ShortsSegment(start: max(start, $0.start), end: min(end, $0.end)) }
        .filter { $0.duration > 0 }
        guard !found.isEmpty else { return whole }

        // Ролик не должен усохнуть ниже осмысленной длины: если пауз слишком
        // много, оставляем самые длинные, пока укладываемся в запас.
        let budget = duration - ShortsLimits.discardBelow
        guard budget > 0 else { return whole }
        var removed = 0.0
        var kept: [ShortsSegment] = []
        for pause in found.sorted(by: { $0.duration > $1.duration }) {
            guard removed + pause.duration <= budget else { continue }
            removed += pause.duration
            kept.append(pause)
        }
        guard !kept.isEmpty else { return whole }
        kept.sort { $0.start < $1.start }

        var result: [ShortsSegment] = []
        var cursor = start
        var droppedLeadIn = false
        for pause in kept {
            if pause.start - cursor < ShortsLimits.minSegmentDuration {
                // Обрывок речи перед паузой дал бы дёрганый монтаж. В начале
                // ролика это просто мёртвый воздух — его выбрасываем целиком;
                // в середине оставляем паузу нетронутой, чтобы не съесть речь.
                if result.isEmpty, !droppedLeadIn {
                    droppedLeadIn = true
                    cursor = pause.end
                }
                continue
            }
            result.append(ShortsSegment(start: cursor, end: pause.start))
            cursor = pause.end
        }
        // Хвост добавляем даже коротким: после него нет склейки, дёргаться нечему.
        if cursor < end { result.append(ShortsSegment(start: cursor, end: end)) }
        return result.isEmpty ? whole : result
    }
}
