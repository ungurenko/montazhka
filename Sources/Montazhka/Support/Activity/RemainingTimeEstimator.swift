import Foundation

/// Оценка оставшегося времени по скорости последних секунд.
///
/// Правило одно: молчать, пока не уверены. Пустой ответ честнее числа,
/// которое через секунду изменится вдвое, — именно так раньше врала
/// шкала прогресса с зашитыми константами.
struct RemainingTimeEstimator {
    /// Сколько секунд истории учитываем. Средняя скорость с самого начала
    /// «залипает» и перестаёт реагировать на замедление.
    private let window: TimeInterval = 30
    /// Минимальное время работы, до которого оценку не показываем.
    private let warmUp: TimeInterval = 8
    private let minimumSamples = 3
    /// На сколько оценке позволено вырасти за один шаг: без этого
    /// цифра дёргается вверх-вниз и выглядит выдумкой.
    private let maximumGrowth: TimeInterval = 10

    private var samples: [(at: Date, fraction: Double)] = []
    private var reported: TimeInterval?

    /// Принимает новую долю выполнения и возвращает оценку остатка,
    /// либо `nil`, если уверенности пока нет.
    mutating func record(fraction: Double, now: Date = Date()) -> TimeInterval? {
        let clamped = min(max(fraction, 0), 1)
        // Доля вернулась назад — работа началась заново, история не годится.
        if let last = samples.last, clamped < last.fraction - 0.01 {
            reset()
        }
        samples.append((now, clamped))
        // Оставляем только свежие семплы, но никогда не меньше минимума,
        // иначе оценка будет сбрасываться на длинных операциях.
        let fresh = samples.filter { now.timeIntervalSince($0.at) <= window }
        samples = fresh.count >= minimumSamples ? fresh : Array(samples.suffix(minimumSamples))

        guard let first = samples.first, let last = samples.last else { return nil }
        let span = last.at.timeIntervalSince(first.at)
        let advance = last.fraction - first.fraction

        guard samples.count >= minimumSamples, span >= warmUp, advance > 0, last.fraction < 0.999 else {
            return reported
        }

        let rate = advance / span
        let candidate = (1 - last.fraction) / rate
        let smoothed = smooth(candidate)
        reported = smoothed
        return smoothed
    }

    mutating func reset() {
        samples.removeAll()
        reported = nil
    }

    private func smooth(_ candidate: TimeInterval) -> TimeInterval {
        guard let previous = reported else { return candidate }
        return min(candidate, previous + maximumGrowth)
    }
}
