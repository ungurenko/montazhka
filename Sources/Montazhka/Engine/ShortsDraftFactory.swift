import Foundation

enum ShortsDraftError: LocalizedError, Equatable {
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case .invalid(let message): message
        }
    }
}

/// Превращает выбор агента (куски по номерам слов, наезды, музыка) в ленту
/// черновика шортса. Чистая логика: пики громкости и длительности подаются
/// снаружи, файлов и AVFoundation здесь нет.
enum ShortsDraftFactory {
    /// Кусок будущего ролика: слова #from…#to расшифровки проекта или
    /// секунды ленты проекта start…end.
    struct Piece: Codable, Equatable, Sendable {
        var from: Int?
        var to: Int?
        var start: Double?
        var end: Double?
    }

    /// Один ролик, как его описал агент.
    struct Spec: Codable, Equatable, Sendable {
        var title: String
        var hook: String?
        var subtitles: Bool?
        var pieces: [Piece]
        var layout: ShortsDraftLayout?
        /// nil — наезды подбираются сами; [] — без наездов.
        var zooms: [AgentWordRange]?
        /// id трека, "none" — без музыки; nil — по `mood`.
        var music: String?
        var mood: String?
    }

    static let zoomScale = 1.08
    static let musicVolume = 25.0

    /// Клипы черновика в порядке кусков. `map` — слова ленты проекта с номерами.
    static func clips(
        for pieces: [Piece], map: [MappedTranscriptWord], clips: [Clip],
        peaksFor: (String) -> [Float]?, sourceDuration: (UUID) -> Double,
        thresholdDB: Double, trimPauses: Bool, removeFillers: Bool
    ) throws -> [Clip] {
        guard !pieces.isEmpty else { throw ShortsDraftError.invalid("У ролика нет ни одного куска (pieces).") }
        let sources = Dictionary(clips.map { ($0.source.id, $0.source) }, uniquingKeysWith: { first, _ in first })
        var result: [Clip] = []
        for piece in pieces {
            if let from = piece.from, let to = piece.to {
                guard from >= 1, to >= from, to <= map.count else {
                    throw ShortsDraftError.invalid(
                        "Слова #\(from)–#\(to) вне расшифровки: в ней \(map.count) слов.")
                }
                for group in groupedByClip(Array(map[(from - 1)...(to - 1)])) {
                    guard let first = group.first, let last = group.last, let source = sources[first.sourceID]
                    else { continue }
                    let peaks = peaksFor(source.resolvedURL?.path ?? source.lastKnownPath) ?? []
                    let boundary =
                        ShortsBoundaryResolver.resolve(
                            first: first, last: last, peaks: peaks,
                            sourceDuration: sourceDuration(first.sourceID), thresholdDB: thresholdDB)
                        ?? ShortsBoundaryResolver.Boundary(
                            start: max(0, first.sourceStart - 0.1), end: last.sourceEnd + 0.1)
                    var segments =
                        trimPauses && !peaks.isEmpty
                        ? ShortsSegmentPlanner.segments(
                            start: boundary.start, end: boundary.end, peaks: peaks, thresholdDB: thresholdDB)
                        : [ShortsSegment(start: boundary.start, end: boundary.end)]
                    if removeFillers {
                        let hums = zip(group, group.dropFirst()).compactMap { a, b -> ClosedRange<Double>? in
                            FillerDetector.voicedSpan(
                                from: a.sourceEnd, to: b.sourceStart, peaks: peaks, thresholdDB: thresholdDB
                            ).flatMap { FillerDetector.isLikelyFiller($0) ? $0 : nil }
                        }
                        segments = subtract(hums, from: segments)
                    }
                    segments = keepingWordsWhole(segments, words: group)
                    result += segments.map { Clip(source: source, start: $0.start, end: $0.end) }
                }
            } else if let start = piece.start, let end = piece.end, end > start {
                result += timelineSlice(clips, from: start, to: end)
            } else {
                throw ShortsDraftError.invalid("Кусок задаётся словами {from,to} или секундами ленты {start,end}.")
            }
        }
        guard !result.isEmpty else { throw ShortsDraftError.invalid("Из кусков не получилось ни одного клипа.") }
        return result
    }

    /// Наезды на слова #from…#to — во времени исходника.
    static func zooms(_ spans: [AgentWordRange], map: [MappedTranscriptWord]) throws -> [ShortsZoom] {
        try spans.flatMap { span -> [ShortsZoom] in
            guard span.from >= 1, span.to >= span.from, span.to <= map.count else {
                throw ShortsDraftError.invalid("Наезд на слова #\(span.from)–#\(span.to) вне расшифровки.")
            }
            return groupedByClip(Array(map[(span.from - 1)...(span.to - 1)])).compactMap { group in
                guard let first = group.first, let last = group.last else { return nil }
                return ShortsZoom(
                    sourceID: first.sourceID, sourceStart: first.sourceStart, sourceEnd: last.sourceEnd,
                    scale: zoomScale)
            }
        }
    }

    /// Наезды «сами»: на самые длинные цельные фразы ролика (от четырёх слов),
    /// примерно один на 15 секунд, не раньше конца хука. `map` — слова черновика.
    static func autoZooms(map: [MappedTranscriptWord], total: Double, notBefore: Double) -> [ShortsZoom] {
        var sentences: [[MappedTranscriptWord]] = []
        var current: [MappedTranscriptWord] = []
        for word in map where !word.text.isEmpty {
            if let last = current.last, last.clipID != word.clipID {
                sentences.append(current)
                current = []
            }
            current.append(word)
            if let mark = word.text.last, ".!?…".contains(mark) {
                sentences.append(current)
                current = []
            }
        }
        sentences.append(current)
        let wanted = max(1, Int(total / 15))
        return sentences
            .filter { $0.count >= 4 && ($0.first?.timelineStart ?? 0) >= notBefore }
            .sorted { ($0.last!.timelineEnd - $0.first!.timelineStart) > ($1.last!.timelineEnd - $1.first!.timelineStart) }
            .prefix(wanted)
            .sorted { $0.first!.timelineStart < $1.first!.timelineStart }
            .map {
                ShortsZoom(
                    sourceID: $0[0].sourceID, sourceStart: $0[0].sourceStart,
                    sourceEnd: $0[$0.count - 1].sourceEnd, scale: zoomScale)
            }
    }

    /// Музыка черновика: трек по id, по настроению или без музыки.
    static func music(track: String?, mood: String?, variant: Int) -> MusicSettings {
        if track == "none" { return MusicSettings(enabled: false) }
        let chosen = track.flatMap(MusicLibrary.track(id:)) ?? MusicLibrary.pick(mood: mood ?? "neutral", variant: variant)
        guard let chosen else { return MusicSettings(enabled: false) }
        return MusicSettings(enabled: true, trackID: chosen.id, volume: musicVolume, eqEnabled: true, ducking: true)
    }

    /// Подряд идущие слова одного клипа ленты: из каждой группы — свой кусок.
    private static func groupedByClip(_ words: [MappedTranscriptWord]) -> [[MappedTranscriptWord]] {
        var groups: [[MappedTranscriptWord]] = []
        for word in words {
            if let last = groups.last?.last, last.clipID == word.clipID {
                groups[groups.count - 1].append(word)
            } else {
                groups.append([word])
            }
        }
        return groups
    }

    /// Кусок ленты проекта start…end → куски исходников.
    private static func timelineSlice(_ clips: [Clip], from: Double, to: Double) -> [Clip] {
        let starts = TimelineEditOps.starts(of: clips)
        return zip(clips, starts).compactMap { clip, start in
            let lower = max(from, start)
            let upper = min(to, start + clip.duration)
            guard upper > lower else { return nil }
            return Clip(source: clip.source, start: clip.start + lower - start, end: clip.start + upper - start)
        }
    }

    /// Граница куска, попавшая внутрь слова (по разметке распознавания),
    /// отодвигается к краю слова: иначе слово выпадет из субтитров и номеров,
    /// хотя в звуке оно есть. Соседний кусок при этом не перекрывается.
    private static func keepingWordsWhole(_ segments: [ShortsSegment], words: [MappedTranscriptWord]) -> [ShortsSegment] {
        segments.enumerated().map { index, segment in
            let previousEnd = index > 0 ? segments[index - 1].end : -Double.infinity
            let nextStart = index + 1 < segments.count ? segments[index + 1].start : Double.infinity
            var start = segment.start
            var end = segment.end
            if let word = words.first(where: { $0.sourceStart < start && $0.sourceEnd > start }) {
                start = max(previousEnd, word.sourceStart)
            }
            if let word = words.first(where: { $0.sourceStart < end && $0.sourceEnd > end }) {
                end = min(nextStart, word.sourceEnd)
            }
            return ShortsSegment(start: start, end: end)
        }
    }

    private static func subtract(_ holes: [ClosedRange<Double>], from segments: [ShortsSegment]) -> [ShortsSegment] {
        holes.reduce(segments) { remaining, hole in
            remaining.flatMap { segment -> [ShortsSegment] in
                guard hole.lowerBound < segment.end, hole.upperBound > segment.start else { return [segment] }
                return [
                    ShortsSegment(start: segment.start, end: hole.lowerBound),
                    ShortsSegment(start: hole.upperBound, end: segment.end),
                ].filter { $0.duration >= 0.1 }
            }
        }
    }
}
