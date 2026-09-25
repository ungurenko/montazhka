import Foundation

/// Замена, которую распознавание часто путает: «клод код» → «Claude Code».
/// Слово шаблона, оканчивающееся на `*`, совпадает с любым окончанием:
/// русские падежи иначе потребовали бы перечислять все формы.
struct GlossaryEntry: Codable, Equatable, Sendable {
    var match: [String]
    var replace: String
}

/// Словарь терминов. Применяется к словам расшифровки на лету; номера слов
/// не сдвигаются: термин встаёт в первое слово, остальные слова совпадения
/// становятся пустыми.
struct Glossary: Equatable, Sendable {
    private(set) var entries: [GlossaryEntry]

    init(entries: [GlossaryEntry]) {
        self.entries = entries
    }

    /// Стартовый набор — по реальным ошибкам распознавания в роликах Александра.
    /// Обычные слова («курсор», «код») сюда не входят: заменять их всегда нельзя.
    static let starter: [GlossaryEntry] = [
        GlossaryEntry(match: ["клод код*", "клод-код*"], replace: "Claude Code"),
        GlossaryEntry(match: ["клод*"], replace: "Claude"),
        GlossaryEntry(
            match: ["чат гпт*", "чатгпт*", "чат джипити*", "чат-гпт*", "чат-жпти*", "чат жпти*"], replace: "ChatGPT"),
        GlossaryEntry(match: ["джипити*", "гпт*", "жпти*"], replace: "GPT"),
        GlossaryEntry(match: ["джемини*", "гемини*"], replace: "Gemini"),
        GlossaryEntry(match: ["кодекс*"], replace: "Codex"),
        GlossaryEntry(match: ["антропик*"], replace: "Anthropic"),
        GlossaryEntry(match: ["опен эй ай", "опен ай", "опенаи"], replace: "OpenAI"),
        GlossaryEntry(match: ["опус*"], replace: "Opus"),
        GlossaryEntry(match: ["соннет*"], replace: "Sonnet"),
        GlossaryEntry(match: ["гитхаб*"], replace: "GitHub"),
        GlossaryEntry(match: ["ии"], replace: "ИИ"),
    ]

    static func load(from url: URL) -> Glossary {
        guard let data = try? Data(contentsOf: url),
            let entries = try? JSONDecoder().decode([GlossaryEntry].self, from: data)
        else { return Glossary(entries: starter) }
        return Glossary(entries: entries)
    }

    func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(entries).write(to: url, options: .atomic)
    }

    /// Запоминает замену: то, как слова распознались, → как их писать.
    mutating func remember(original: [String], replacement: String) {
        let pattern = original.map(Self.normalized).filter { !$0.isEmpty }.joined(separator: " ")
        guard !pattern.isEmpty, pattern != Self.normalized(replacement) else { return }
        if let index = entries.firstIndex(where: { $0.replace == replacement }) {
            if !entries[index].match.contains(pattern) { entries[index].match.append(pattern) }
        } else {
            entries.append(GlossaryEntry(match: [pattern], replace: replacement))
        }
    }

    func apply(to words: [TranscriptWord]) -> [TranscriptWord] {
        let patterns = entries.flatMap { entry in
            entry.match.map { (tokens: $0.split(separator: " ").map(String.init), replace: entry.replace) }
        }.sorted { ($0.tokens.count, $0.tokens.joined().count) > ($1.tokens.count, $1.tokens.joined().count) }
        let normalized = words.map { Self.normalized($0.text) }
        var texts = words.map(\.text)
        var index = 0
        while index < words.count {
            guard
                let hit = patterns.first(where: { pattern in
                    index + pattern.tokens.count <= words.count
                        && pattern.tokens.enumerated().allSatisfy { offset, token in
                            Self.matches(normalized[index + offset], token)
                        }
                })
            else {
                index += 1
                continue
            }
            let last = index + hit.tokens.count - 1
            let tail = Self.hyphenTail(words[last].text, token: hit.tokens[hit.tokens.count - 1])
            texts[index] = hit.replace + tail + Self.trailingPunctuation(words[last].text)
            for hidden in (index + 1)..<(last + 1) { texts[hidden] = "" }
            index = last + 1
        }
        return zip(words, texts).map { word, text in word.replacingText(text) }
    }

    /// Слово через дефис («ГПТ-6») сверяется по части до дефиса, а хвост
    /// сохраняется: получается «GPT-6», а не просто «GPT».
    private static func matches(_ word: String, _ token: String) -> Bool {
        guard token.hasSuffix("*") else { return word == token }
        let prefix = String(token.dropLast())
        return !word.isEmpty && (word.hasPrefix(prefix) || stem(word).hasPrefix(prefix))
    }

    private static func stem(_ word: String) -> String {
        String(word.prefix { $0 != "-" })
    }

    /// Хвост после дефиса, если термин совпал только с частью до дефиса.
    private static func hyphenTail(_ text: String, token: String) -> String {
        guard token.hasSuffix("*"), !token.contains("-"), let dash = text.firstIndex(of: "-") else { return "" }
        let tail = text[dash...]
        return String(tail.dropLast(trailingPunctuation(String(tail)).count))
    }

    static func normalized(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: "ё", with: "е")
            .trimmingCharacters(in: .punctuationCharacters.union(.whitespaces).union(.symbols))
    }

    private static func trailingPunctuation(_ text: String) -> String {
        String(text.reversed().prefix { $0.isPunctuation }.reversed())
    }
}

/// Ручные исправления агента для одного исходника: номер слова в его
/// расшифровке → новый текст. Пустой текст прячет слово.
enum TranscriptCorrections {
    /// Файл исправлений лежит рядом с кэшем расшифровки того же исходника.
    static func url(forTranscript cacheURL: URL) -> URL {
        cacheURL.deletingPathExtension().appendingPathExtension("fixes.json")
    }

    static func load(from url: URL) -> [Int: String] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([Int: String].self, from: data)) ?? [:]
    }

    static func save(_ fixes: [Int: String], to url: URL) throws {
        try JSONEncoder().encode(fixes).write(to: url, options: .atomic)
    }

    static func apply(_ fixes: [Int: String], to words: [TranscriptWord]) -> [TranscriptWord] {
        words.enumerated().map { index, word in fixes[index].map(word.replacingText) ?? word }
    }
}

extension TranscriptStore {
    /// Слова уже готовых расшифровок с поправками: словарь, затем ручные
    /// исправления. nil — хотя бы один исходник ещё не расшифрован (сама
    /// расшифровка здесь не запускается: она идёт минутами).
    func correctedCachedWords(for sources: [MediaReference], glossaryURL: URL) async throws -> [TranscriptWord]? {
        for source in sources where !FileManager.default.fileExists(atPath: cacheURL(for: source).path) {
            return nil
        }
        let glossary = Glossary.load(from: glossaryURL)
        var words: [TranscriptWord] = []
        for source in sources {
            let fixes = TranscriptCorrections.load(from: TranscriptCorrections.url(forTranscript: cacheURL(for: source)))
            words += TranscriptCorrections.apply(fixes, to: glossary.apply(to: try await ensure(source: source)))
        }
        return words
    }
}

extension TranscriptWord {
    func replacingText(_ text: String) -> TranscriptWord {
        TranscriptWord(id: id, sourceID: sourceID, text: text, start: start, end: end, confidence: confidence)
    }
}
