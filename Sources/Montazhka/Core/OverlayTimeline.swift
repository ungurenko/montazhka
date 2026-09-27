import Foundation

/// Где анимация встаёт на ленте после всех правок.
struct ResolvedOverlay: Equatable, Sendable {
    enum Status: String, Equatable, Sendable { case visible, anchorCut, tooShort }
    let overlay: ProjectOverlay
    /// Где анимация видна на ленте; пустой диапазон, когда её не видно.
    let window: TimelineRange
    /// С какой секунды файла анимации начинается показ.
    let mediaStart: Double
    /// Начало слова-якоря на ленте; nil, когда якорь вырезан.
    let anchorTimeline: Double?
    /// Сколько раз момент якоря встречается на ленте.
    let occurrences: Int
    let status: Status
}

/// Переводит якорь анимации (момент исходника) во время ленты. Чистые функции:
/// без файлов и AVFoundation. Внутри своего окна анимация идёт непрерывно
/// по времени ленты, даже через склейки.
enum OverlayTimeline {
    /// Окно короче этого не показываем: анимацию не успеть увидеть.
    static let minimumWindow = 0.1
    /// Слово может начинаться чуть раньше клипа (так его показывает расшифровка);
    /// у конца клипа тот же запас в другую сторону.
    private static let edgeTolerance = 0.005

    static func resolve(_ overlays: [ProjectOverlay], clips: [Clip]) -> [ResolvedOverlay] {
        let total = clips.reduce(0) { $0 + $1.duration }
        return overlays.map { resolve($0, clips: clips, totalDuration: total) }
    }

    /// Все места ленты, где виден момент якоря, по порядку. Конец клипа в него
    /// не входит: кадр на границе уже играет следующий клип, поэтому слово,
    /// вырезанное ровно от своего начала, считается вырезанным.
    static func timelineTimes(of anchor: OverlayAnchor, clips: [Clip]) -> [Double] {
        zip(clips, TimelineEditOps.starts(of: clips)).compactMap { clip, clipStart in
            guard clip.source.id == anchor.sourceID,
                clip.start - edgeTolerance <= anchor.sourceTime, anchor.sourceTime < clip.end - edgeTolerance
            else { return nil }
            return clipStart + max(0, anchor.sourceTime - clip.start)
        }
    }

    /// Якорь для момента ленты: момент исходника под ним. Со словами якорь
    /// встаёт на начало слова под этим моментом или следующего за ним.
    static func anchor(atTimeline time: Double, clips: [Clip], words: [MappedTranscriptWord]?) -> OverlayAnchor? {
        let starts = TimelineEditOps.starts(of: clips)
        guard let last = clips.last, let lastStart = starts.last, time >= 0, time <= lastStart + last.duration
        else { return nil }
        let word = words?.filter { $0.timelineEnd > time }.min { $0.timelineStart < $1.timelineStart }
        if let word {
            return OverlayAnchor(sourceID: word.sourceID, sourceTime: word.sourceStart, wordText: word.text)
        }
        let index = starts.lastIndex { $0 <= time } ?? 0
        let clip = clips[index]
        return OverlayAnchor(
            sourceID: clip.source.id, sourceTime: min(clip.end, clip.start + time - starts[index]), wordText: nil)
    }

    private static func resolve(_ overlay: ProjectOverlay, clips: [Clip], totalDuration: Double) -> ResolvedOverlay {
        let times = timelineTimes(of: overlay.anchor, clips: clips)
        guard let anchorTime = times.first else {
            return ResolvedOverlay(
                overlay: overlay, window: TimelineRange(from: 0, to: 0), mediaStart: 0,
                anchorTimeline: nil, occurrences: 0, status: .anchorCut)
        }
        var start = anchorTime - (overlay.align == .payoff ? overlay.payoffAt : 0)
        var mediaStart = 0.0
        if start < 0 {
            mediaStart = -start
            start = 0
        }
        let end = min(start + overlay.duration - mediaStart, totalDuration)
        let visible = end - start >= minimumWindow
        return ResolvedOverlay(
            overlay: overlay, window: TimelineRange(from: start, to: visible ? end : start),
            mediaStart: mediaStart, anchorTimeline: anchorTime, occurrences: times.count,
            status: visible ? .visible : .tooShort)
    }
}
