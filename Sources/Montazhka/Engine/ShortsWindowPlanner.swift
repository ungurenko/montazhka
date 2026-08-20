import Foundation

/// Разбивает транскрипт на окна для порционного анализа ИИ и разбирает
/// пересечения кандидатов из соседних окон.
enum ShortsWindowPlanner {
    /// Окно 15 минут — компактный вызов LLM даже при быстром темпе речи.
    static let windowDuration = 900.0
    /// Перекрытие соседних окон: сильный момент на стыке не теряется.
    static let overlap = 30.0

    /// Диапазоны индексов слов. Слово попадает во все окна, накрывающие его
    /// по времени начала; возможные дубли кандидатов разбирает дедупликация.
    static func windows(for words: [MappedTranscriptWord]) -> [Range<Int>] {
        guard let first = words.first, let last = words.last else { return [] }
        guard last.timelineEnd > first.timelineStart else { return [0..<words.count] }

        let step = windowDuration - overlap
        var result: [Range<Int>] = []
        var windowStart = first.timelineStart
        while windowStart < last.timelineEnd {
            let windowEnd = windowStart + windowDuration
            let lower = firstIndex(of: words, atOrAfter: windowStart, from: 0)
            let upper = firstIndex(of: words, atOrAfter: windowEnd, from: lower)
            if lower < upper { result.append(lower..<upper) }
            windowStart += step
        }
        return result.isEmpty ? [0..<words.count] : result
    }

    /// Убирает пересекающихся по времени кандидатов. Вход должен быть
    /// отсортирован по рангу: из пересечения остаётся более сильный.
    static func deduplicated(_ candidates: [ShortCandidate]) -> [ShortCandidate] {
        var kept: [ShortCandidate] = []
        for candidate in candidates
        where
            !kept.contains(where: { $0.start < candidate.end && candidate.start < $0.end })
        {
            kept.append(candidate)
        }
        return kept
    }

    /// Модель не всегда удерживает потолок в 60 секунд: обрезаем хвост
    /// диапазона по словам, сохраняя цепляющее начало. nil — даже после
    /// обрезки фрагмент короче минимально осмысленного.
    static func trimmedToMaxDuration(
        _ words: ArraySlice<MappedTranscriptWord>
    ) -> ArraySlice<MappedTranscriptWord>? {
        guard let first = words.first else { return nil }
        var upper = words.endIndex
        while upper > words.startIndex,
            words[upper - 1].sourceEnd - first.sourceStart > ShortsLimits.maxDuration
        {
            upper = words.index(before: upper)
        }
        let trimmed = words[words.startIndex..<upper]
        guard let last = trimmed.last,
            last.sourceEnd - first.sourceStart >= ShortsLimits.discardBelow
        else { return nil }
        return trimmed
    }

    private static func firstIndex(
        of words: [MappedTranscriptWord],
        atOrAfter time: Double,
        from start: Int
    ) -> Int {
        var index = start
        while index < words.count, words[index].timelineStart < time { index += 1 }
        return index
    }
}
