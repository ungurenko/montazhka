import Foundation

/// Диапазон слов по номерам из `montazhka_transcript` (с 1, включительно).
struct AgentWordRange: Codable, Equatable, Sendable {
    let from: Int
    let to: Int
}

/// Один рез по словам. `inSilence == false` — тихой точки рядом не нашлось,
/// рез идёт по границе слова из расшифровки и его стоит проверить.
struct AgentWordCut: Equatable, Sendable {
    let range: TimelineRange
    let inSilence: Bool
    /// Номера слов этого куска (с 1).
    let words: ClosedRange<Int>
}

/// Резы по словам: агент называет номера слов, а точку реза в тишине
/// между словами находит движок. Агенту не нужно считать секунды.
enum AgentWordCuts {
    /// Сколько «воздуха» оставлять у соседних слов, если тихой точки рядом нет.
    private static let fallbackAir = 0.06

    /// Отпечаток ленты: номера слов верны, пока он не изменился.
    static func fingerprint(_ clips: [Clip]) -> String {
        String(SmartEditSnapshot(clips: clips).id.prefix(12))
    }

    /// Номера слов → диапазоны ленты для `delete`. Слова по разные стороны
    /// склейки режутся отдельными кусками — у каждого клипа своя тишина.
    static func timelineRanges(
        _ ranges: [AgentWordRange], map: TranscriptTimelineMap, clips: [Clip],
        peaksFor: (String) -> [Float]?, thresholdDB: Double
    ) throws -> [AgentWordCut] {
        let words = map.words
        let starts = Dictionary(uniqueKeysWithValues: zip(clips.map(\.id), TimelineEditOps.starts(of: clips)))
        var result: [AgentWordCut] = []
        for range in ranges {
            guard range.from >= 1, range.to >= range.from, range.to <= words.count else {
                throw AgentServiceError.invalidInput(
                    "Слов с номерами \(range.from)–\(range.to) нет: в расшифровке \(words.count) слов.")
            }
            var first = range.from - 1
            while first < range.to {
                var last = first
                while last + 1 < range.to, words[last + 1].clipID == words[first].clipID { last += 1 }
                if let cut = cut(
                    words: words, first: first, last: last, clips: clips, starts: starts,
                    peaksFor: peaksFor, thresholdDB: thresholdDB)
                {
                    result.append(cut)
                }
                first = last + 1
            }
        }
        return result
    }

    private static func cut(
        words: [MappedTranscriptWord], first: Int, last: Int, clips: [Clip], starts: [UUID: Double],
        peaksFor: (String) -> [Float]?, thresholdDB: Double
    ) -> AgentWordCut? {
        let clipID = words[first].clipID
        guard let clip = clips.first(where: { $0.id == clipID }), let clipStart = starts[clipID] else { return nil }
        let numbers = (first + 1)...(last + 1)
        if let peaks = peaksFor(clip.sourcePath),
            let boundary = SmartCutBoundaryResolver.resolve(
                words: words[first...last], clip: clip, clipTimelineStart: clipStart,
                peaks: peaks, projectThresholdDB: thresholdDB)
        {
            return AgentWordCut(
                range: TimelineRange(from: boundary.timelineStart, to: boundary.timelineEnd),
                inSilence: true, words: numbers)
        }
        // Тихой точки рядом нет: режем в промежутке до соседних слов, не дальше «воздуха».
        let previousEnd = first > 0 && words[first - 1].clipID == clipID ? words[first - 1].timelineEnd : clipStart
        let nextStart =
            last + 1 < words.count && words[last + 1].clipID == clipID
            ? words[last + 1].timelineStart : clipStart + clip.duration
        let from = words[first].timelineStart - min(fallbackAir, max(0, words[first].timelineStart - previousEnd) / 2)
        let to = words[last].timelineEnd + min(fallbackAir, max(0, nextStart - words[last].timelineEnd) / 2)
        return AgentWordCut(
            range: TimelineRange(from: from, to: max(to, from + 0.01)), inSilence: false, words: numbers)
    }
}

/// Поиск фразы в расшифровке без учёта регистра, «ё» и знаков препинания.
/// Каждое слово запроса совпадает с началом слова: «тариф» находит «тарифах».
enum TranscriptSearch {
    static func normalize(_ text: String) -> String {
        String(text.lowercased().replacingOccurrences(of: "ё", with: "е").filter { $0.isLetter || $0.isNumber })
    }

    /// Номера (с 0) первого и последнего слова каждого вхождения.
    static func matches(of query: String, in words: [String]) -> [ClosedRange<Int>] {
        let needle = query.split(whereSeparator: \.isWhitespace).map { normalize(String($0)) }.filter { !$0.isEmpty }
        let haystack = words.map(normalize)
        guard !needle.isEmpty, haystack.count >= needle.count else { return [] }
        return (0...(haystack.count - needle.count)).compactMap { start in
            let found = needle.indices.allSatisfy { offset in
                let word = haystack[start + offset]
                return !word.isEmpty && word.hasPrefix(needle[offset])
            }
            return found ? start...(start + needle.count - 1) : nil
        }
    }
}
