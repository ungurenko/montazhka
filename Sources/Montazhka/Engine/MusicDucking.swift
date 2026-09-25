import Foundation

/// Огибающая громкости фоновой музыки: плавный вход, затухание в конце
/// и, если известны участки речи, приглушение под голосом.
enum MusicDucking {
    struct Point: Equatable {
        let time: Double
        let volume: Double
    }

    /// Во сколько раз музыка тише под речью.
    static let duckRatio = 0.35
    static let attack = 0.15
    static let release = 0.4
    /// Паузы короче этой — вдох между фразами: музыка не успевает подняться.
    static let minGap = 0.6

    static func envelope(speech: [TimelineRange], total: Double, level: Double) -> [Point] {
        guard total > 0 else { return [] }
        let fadeIn = min(1.0, total / 4)
        let fadeOut = min(3.0, total / 3)
        let duck = duckPoints(merged(speech, total: total))

        var times: Set<Double> = [0, fadeIn, total - fadeOut, total]
        for point in duck where point.time > 0 && point.time < total { times.insert(point.time) }
        return times.sorted().map { time in
            let fade = min(1, time / fadeIn, (total - time) / fadeOut)
            return Point(time: time, volume: max(0, level * fade * interpolate(duck, at: time)))
        }
    }

    /// Речь в пределах ролика; соседние фразы с короткой паузой — одна.
    private static func merged(_ speech: [TimelineRange], total: Double) -> [TimelineRange] {
        var result: [TimelineRange] = []
        for range in speech.sorted(by: { $0.from < $1.from }) {
            let from = max(0, range.from)
            let to = min(total, range.to)
            guard to > from else { continue }
            if let last = result.last, from - last.to < minGap {
                result[result.count - 1] = TimelineRange(from: last.from, to: max(last.to, to))
            } else {
                result.append(TimelineRange(from: from, to: to))
            }
        }
        return result
    }

    /// Множитель громкости: 1 в паузах, `duckRatio` под речью.
    private static func duckPoints(_ speech: [TimelineRange]) -> [Point] {
        speech.flatMap { range in
            [
                Point(time: range.from - attack, volume: 1),
                Point(time: range.from, volume: duckRatio),
                Point(time: range.to, volume: duckRatio),
                Point(time: range.to + release, volume: 1),
            ]
        }
    }

    private static func interpolate(_ points: [Point], at time: Double) -> Double {
        guard let first = points.first, time > first.time else { return points.first?.volume ?? 1 }
        for (a, b) in zip(points, points.dropFirst()) where time <= b.time {
            let span = b.time - a.time
            return span <= 0 ? b.volume : a.volume + (b.volume - a.volume) * (time - a.time) / span
        }
        return points.last?.volume ?? 1
    }
}
