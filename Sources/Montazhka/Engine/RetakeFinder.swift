import Foundation

/// Фраза расшифровки: слова подряд без паузы ≥ `RetakeFinder.phraseGap` и без склейки.
/// `firstWord`/`lastWord` — номера слов в массиве (с 0); `montazhka_transcript`
/// показывает агенту то же слово как `#(номер + 1)`. Время — время ленты.
struct TranscriptPhrase: Equatable, Sendable {
    let index: Int
    let firstWord: Int
    let lastWord: Int
    let start: Double
    let end: Double
    let text: String
}

/// Соседние похожие фразы — вероятные дубли. Это подсказка: какой дубль оставить, решает агент.
struct RetakeGroup: Equatable, Sendable {
    /// `restart` — оборванное начало (фальстарт), `repeat` — фраза сказана заново.
    enum Kind: String, Sendable {
        case restart
        case `repeat`
    }

    /// Номера фраз (`TranscriptPhrase.index`) по порядку.
    let phrases: [Int]
    /// Самая слабая связь в цепочке дублей.
    let similarity: Double
    /// Вид самой слабой связи — той, что дала `similarity`.
    let kind: Kind
}

/// Подсказки о дублях для записей «говорящей головы»: человек сбился и сказал фразу заново.
enum RetakeFinder {
    /// Пауза, с которой начинается новая фраза (секунды).
    static let phraseGap = 0.5
    /// Со сколькими следующими фразами сравнивать каждую.
    static let lookahead = 4
    /// Дальше этого (секунды от конца фразы до начала другой) дубли не ищем.
    static let maxSpan = 30.0
    /// С такой похожести фразы считаются дублями.
    static let minSimilarity = 0.6
    /// Больше групп агенту не нужно — он всё равно разбирает их по одной.
    static let maxGroups = 50
    /// Общее начало такой длины — одно слово с другим окончанием («сделаем»/«сделаю»).
    static let sharedStem = 4

    /// Новая фраза — после паузы ≥ `phraseGap` или на склейке (другой клип).
    /// Пустое слово — хвост термина, исправленного `fixWords`: его звук принадлежит
    /// предыдущему слову. Фразу оно не начинает и не рвёт, в текст и сравнение не идёт,
    /// но входит в её `lastWord`/`end`, чтобы удаление фразы по номерам слов не оставило обрывок.
    static func phrases(_ words: [MappedTranscriptWord]) -> [TranscriptPhrase] {
        var result: [TranscriptPhrase] = []
        var current: PhraseDraft?

        for (index, word) in words.enumerated() {
            let text = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let continues = current.map { draft in
                let previous = words[draft.last]
                return previous.clipID == word.clipID && word.timelineStart - previous.timelineEnd < phraseGap
            }
            if text.isEmpty {
                if continues == true { current?.last = index }
                continue
            }
            if continues != true {
                if let draft = current { result.append(draft.phrase(index: result.count, words: words)) }
                current = PhraseDraft(first: index, last: index, texts: [])
            }
            current?.last = index
            current?.texts.append(text)
        }
        if let draft = current { result.append(draft.phrase(index: result.count, words: words)) }
        return result
    }

    /// Каждая фраза сравнивается со следующими `lookahead` фразами в пределах `maxSpan`;
    /// похожие пары сцепляются в группы (A~B, B~C → [A, B, C]). Не больше `maxGroups`, ранние первыми.
    static func retakes(_ phrases: [TranscriptPhrase], words: [MappedTranscriptWord]) -> [RetakeGroup] {
        let tokens = phrases.map { self.tokens($0, words: words) }
        var links: [Link] = []
        for first in phrases.indices {
            for second in (first + 1)..<min(phrases.count, first + lookahead + 1)
            where phrases[second].start - phrases[first].end <= maxSpan {
                let pair = similarity(tokens[first], tokens[second])
                if pair.score >= minSimilarity {
                    links.append(Link(first: first, second: second, score: pair.score, kind: pair.kind))
                }
            }
        }

        var roots = Array(phrases.indices)
        func root(_ position: Int) -> Int {
            var position = position
            while roots[position] != position { position = roots[position] }
            return position
        }
        for link in links {
            let (a, b) = (root(link.first), root(link.second))
            if a != b { roots[max(a, b)] = min(a, b) }
        }

        var members: [Int: Set<Int>] = [:]
        var weakest: [Int: Link] = [:]
        for link in links {
            let group = root(link.first)
            members[group, default: []].formUnion([link.first, link.second])
            if let current = weakest[group], current.score <= link.score { continue }
            weakest[group] = link
        }
        return members.keys.sorted().prefix(maxGroups).compactMap { group in
            guard let link = weakest[group], let positions = members[group] else { return nil }
            return RetakeGroup(
                phrases: positions.sorted().map { phrases[$0].index }, similarity: link.score, kind: link.kind)
        }
    }

    /// Похожесть двух фраз по нормализованным словам; берётся лучший из двух видов.
    /// `repeat`: 2·LCS/(|a|+|b|), обе фразы от 3 слов. `restart`: `a` короче `b` (от 2 слов),
    /// LCS(a, первые |a| слов b)/|a|. Пара фраз из 1–2 слов («да, да» / «да, да») поэтому
    /// всегда даёт 0 — это не дубль.
    static func similarity(_ a: [String], _ b: [String]) -> (score: Double, kind: RetakeGroup.Kind) {
        var best: (score: Double, kind: RetakeGroup.Kind) = (0, .repeat)
        if a.count >= 3, b.count >= 3 {
            best = (2 * Double(alignment(a, b).count) / Double(a.count + b.count), .repeat)
        }
        if a.count >= 2, a.count < b.count {
            let restart = Double(alignment(a, Array(b.prefix(a.count))).count) / Double(a.count)
            if restart > best.score { best = (restart, .restart) }
        }
        return best
    }

    /// Одно и то же слово: совпадает целиком или начинается одинаково на `sharedStem`+ букв.
    static func tokensMatch(_ a: String, _ b: String) -> Bool {
        guard a != b else { return true }
        var shared = 0
        for (left, right) in zip(a, b) {
            guard left == right else { break }
            shared += 1
            if shared >= sharedStem { return true }
        }
        return false
    }

    /// Наибольшая общая подпоследовательность слов (правило `tokensMatch`):
    /// пары номеров (в `a`, в `b`) по возрастанию.
    static func alignment(_ a: [String], _ b: [String]) -> [(Int, Int)] {
        guard !a.isEmpty, !b.isEmpty else { return [] }
        let width = b.count + 1
        var table = [Int](repeating: 0, count: (a.count + 1) * width)
        for i in 1...a.count {
            for j in 1...b.count {
                table[i * width + j] =
                    tokensMatch(a[i - 1], b[j - 1])
                    ? table[(i - 1) * width + j - 1] + 1
                    : max(table[(i - 1) * width + j], table[i * width + j - 1])
            }
        }
        var pairs: [(Int, Int)] = []
        var (i, j) = (a.count, b.count)
        while i > 0, j > 0 {
            if tokensMatch(a[i - 1], b[j - 1]), table[i * width + j] == table[(i - 1) * width + j - 1] + 1 {
                pairs.append((i - 1, j - 1))
                i -= 1
                j -= 1
            } else if table[(i - 1) * width + j] >= table[i * width + j - 1] {
                i -= 1
            } else {
                j -= 1
            }
        }
        return pairs.reversed()
    }

    /// Нормализованные слова фразы без пустых.
    private static func tokens(_ phrase: TranscriptPhrase, words: [MappedTranscriptWord]) -> [String] {
        guard phrase.firstWord >= 0, phrase.firstWord <= phrase.lastWord, phrase.lastWord < words.count else {
            return []
        }
        return words[phrase.firstWord...phrase.lastWord].map { TranscriptSearch.normalize($0.text) }
            .filter { !$0.isEmpty }
    }

    private struct PhraseDraft {
        let first: Int
        var last: Int
        var texts: [String]

        func phrase(index: Int, words: [MappedTranscriptWord]) -> TranscriptPhrase {
            TranscriptPhrase(
                index: index, firstWord: first, lastWord: last,
                start: words[first].timelineStart, end: words[last].timelineEnd,
                text: texts.joined(separator: " "))
        }
    }

    private struct Link {
        let first: Int
        let second: Int
        let score: Double
        let kind: RetakeGroup.Kind
    }
}
