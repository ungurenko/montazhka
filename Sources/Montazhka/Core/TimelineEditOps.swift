import Foundation

/// Диапазон ленты в секундах.
public struct TimelineRange: Equatable, Sendable {
    public let from: Double
    public let to: Double

    public init(from: Double, to: Double) {
        self.from = from
        self.to = to
    }
}

/// Одна правка ленты от агента. Все времена — секунды ленты (итогового ролика),
/// кроме `insert`, где `start`/`end` — секунды исходного файла.
public enum TimelineEditOp: Equatable, Sendable {
    case delete(ranges: [TimelineRange])
    case split(at: Double)
    case move(clip: Int, to: Int)
    case trim(clip: Int, edge: TimelineTrimEdge, seconds: Double)
    case insert(sourcePath: String, start: Double, end: Double, at: Double)
}

public enum TimelineEditError: LocalizedError, Equatable {
    case invalidRange(Double, Double)
    case outsideTimeline(Double)
    case noClip(Int)
    case tooClose(Double)
    case beyondSource(Int)
    case emptyTimeline

    public var errorDescription: String? {
        switch self {
        case .invalidRange(let from, let to): "Неверный диапазон \(from)–\(to): конец должен быть больше начала."
        case .outsideTimeline(let time): "Время \(time) за пределами ленты."
        case .noClip(let index): "Клипа с номером \(index) нет. Номера смотрите в montazhka_inspect."
        case .tooClose(let time): "Точка \(time) слишком близко к краю клипа."
        case .beyondSource(let index): "Клип \(index) нельзя растянуть за пределы исходника."
        case .emptyTimeline: "После правки лента осталась бы пустой."
        }
    }
}

/// Чистые правки ленты: без файлов и сети, поэтому легко проверяются тестами.
public enum TimelineEditOps {
    /// Применяет правки по порядку: каждая видит результат предыдущей.
    /// `sourceDurations` — длины исходников по пути (нужны `trim` и `insert`,
    /// чтобы не выйти за конец файла).
    public static func apply(
        _ ops: [TimelineEditOp], to clips: [Clip], sourceDurations: [String: Double]
    ) throws -> [Clip] {
        var result = clips
        for op in ops {
            result = try apply(op, to: result, sourceDurations: sourceDurations)
        }
        guard !result.isEmpty else { throw TimelineEditError.emptyTimeline }
        return result
    }

    /// Начало каждого клипа на ленте.
    public static func starts(of clips: [Clip]) -> [Double] {
        var acc = 0.0
        return clips.map { clip in
            defer { acc += clip.duration }
            return acc
        }
    }

    private static func apply(
        _ op: TimelineEditOp, to clips: [Clip], sourceDurations: [String: Double]
    ) throws -> [Clip] {
        let total = clips.reduce(0) { $0 + $1.duration }
        switch op {
        case .delete(let ranges):
            for range in ranges where !(range.to > range.from) || !range.from.isFinite || !range.to.isFinite {
                throw TimelineEditError.invalidRange(range.from, range.to)
            }
            // Пересечения сливаем, затем режем с конца: ранние диапазоны остаются
            // в координатах ленты ДО операции.
            return merged(ranges).reversed().reduce(clips) {
                TimelineOps.removingRange(clips: $0, start: $1.from, end: $1.to)
            }
        case .split(let at):
            guard at > 0, at < total else { throw TimelineEditError.outsideTimeline(at) }
            let (index, offset) = locate(at, in: clips)
            guard let result = TimelineOps.splitting(clips: clips, at: index, offset: offset) else {
                throw TimelineEditError.tooClose(at)
            }
            return result
        case .move(let from, let to):
            guard clips.indices.contains(from) else { throw TimelineEditError.noClip(from) }
            guard clips.indices.contains(to) else { throw TimelineEditError.noClip(to) }
            var result = clips
            result.insert(result.remove(at: from), at: to)
            return result
        case .trim(let index, let edge, let seconds):
            guard clips.indices.contains(index) else { throw TimelineEditError.noClip(index) }
            var clip = clips[index]
            let limit = sourceDurations[clip.sourcePath] ?? clip.end
            switch edge {
            case .start: clip.start += seconds
            case .end: clip.end -= seconds
            }
            guard clip.start >= -0.001, clip.end <= limit + 0.001 else { throw TimelineEditError.beyondSource(index) }
            clip.start = max(0, clip.start)
            clip.end = min(limit, clip.end)
            guard clip.duration >= 0.1 else { throw TimelineEditError.tooClose(seconds) }
            var result = clips
            result[index] = clip
            return result
        case .insert(let path, let start, let end, let at):
            guard end > start, start >= 0 else { throw TimelineEditError.invalidRange(start, end) }
            if let limit = sourceDurations[path], end > limit + 0.001 {
                throw TimelineEditError.invalidRange(start, end)
            }
            guard at >= 0, at <= total + 0.001 else { throw TimelineEditError.outsideTimeline(at) }
            let piece = Clip(sourcePath: path, start: start, end: min(end, sourceDurations[path] ?? end))
            if at >= total - 0.001 { return clips + [piece] }
            let (index, offset) = locate(at, in: clips)
            if offset < 0.001 {
                var result = clips
                result.insert(piece, at: index)
                return result
            }
            guard var result = TimelineOps.splitting(clips: clips, at: index, offset: offset) else {
                throw TimelineEditError.tooClose(at)
            }
            result.insert(piece, at: index + 1)
            return result
        }
    }

    private static func merged(_ ranges: [TimelineRange]) -> [TimelineRange] {
        var result: [TimelineRange] = []
        for range in ranges.sorted(by: { $0.from < $1.from }) {
            if let last = result.last, range.from <= last.to {
                result[result.count - 1] = TimelineRange(from: last.from, to: max(last.to, range.to))
            } else {
                result.append(range)
            }
        }
        return result
    }

    /// Клип, в который попадает время ленты, и смещение внутри него.
    private static func locate(_ time: Double, in clips: [Clip]) -> (index: Int, offset: Double) {
        var acc = 0.0
        for (index, clip) in clips.enumerated() {
            if time < acc + clip.duration { return (index, time - acc) }
            acc += clip.duration
        }
        return (max(0, clips.count - 1), clips.last?.duration ?? 0)
    }
}
