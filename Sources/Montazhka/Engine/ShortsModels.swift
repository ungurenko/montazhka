import Foundation

/// Как исходное видео размещается в готовом кадре shorts.
enum ShortsFrameMode: String, CaseIterable, Identifiable, Sendable {
    case original
    case verticalCrop
    case verticalFit

    var id: String { rawValue }

    var title: String {
        switch self {
        case .original: "Исходный"
        case .verticalCrop: "Вырез 9:16"
        case .verticalFit: "Целиком 9:16"
        }
    }

    var subtitle: String {
        switch self {
        case .original: "Сохраняет формат исходного видео"
        case .verticalCrop: "Заполняет весь экран, края кадра обрезаются"
        case .verticalFit: "Видео остаётся целиком, свободное место заполняется фоном"
        }
    }

    static let key = "shorts.frameMode"
    static let legacyCropKey = "shorts.cropVertical"
}

/// Цвет свободного места в режиме «Целиком 9:16».
enum ShortsCanvasColor: String, CaseIterable, Identifiable, Sendable {
    case black
    case white

    var id: String { rawValue }

    var title: String {
        switch self {
        case .black: "Чёрный"
        case .white: "Белый"
        }
    }

    static let key = "shorts.canvasColor"

}

/// Сколько роликов хочет получить пользователь.
enum ShortsCount: String, CaseIterable, Identifiable, Sendable {
    case three = "3"
    case five = "5"
    case eight = "8"
    case auto = "auto"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .three: return "3"
        case .five: return "5"
        case .eight: return "8"
        case .auto: return "Авто"
        }
    }

    /// Желаемое число роликов для ИИ. nil — ИИ решает сам.
    var desired: Int? {
        switch self {
        case .three: return 3
        case .five: return 5
        case .eight: return 8
        case .auto: return nil
        }
    }

    static let key = "shorts.count"

    /// Восстановленное значение из хранилища настроек; по умолчанию — `.five`.
    static func saved(in store: any PreferenceStoring = UserDefaultsPreferenceStore.standard) -> ShortsCount {
        guard let raw = store.string(forKey: key) else { return .five }
        return ShortsCount(rawValue: raw) ?? .five
    }

    func save(in store: any PreferenceStoring = UserDefaultsPreferenceStore.standard) {
        store.set(rawValue, forKey: Self.key)
    }
}

enum ShortsLimits {
    /// Жёсткий потолок длительности ролика.
    static let maxDuration = 60.0
    /// Целевой минимум из промпта; короче `discardBelow` результат отбрасывается.
    static let minDuration = 15.0
    static let discardBelow = 12.0
    /// Не больше десяти кандидатов, даже если ИИ нашёл больше.
    static let maxCandidates = 10
    /// Видео короче этого нарезать бессмысленно.
    static let minSourceDuration = 20.0
}

/// Кандидат в ролики: границы в секундах исходника, заголовок и ранг силы.
struct ShortCandidate: Identifiable, Equatable, Sendable {
    let id: UUID
    let rank: Int
    let title: String
    let reason: String
    /// Первые слова ролика — что зритель услышит в начале.
    let hook: String
    /// Вирусный паттерн одним-двумя словами («мнение», «история»…).
    let pattern: String
    let excerpt: String
    let start: Double
    let end: Double
    let confidence: Double
    /// Баллы решётки оценки 0–10: хук, самостоятельность, польза, темп.
    let hookScore: Int
    let standaloneScore: Int
    let payoffScore: Int
    let pacingScore: Int
    var enabled: Bool

    var duration: Double { max(0, end - start) }
}

enum ShortsStatus: Equatable {
    case idle
    case preparingModel(progress: Double?)
    case transcribing(progress: Double?)
    case mapping(done: Int, total: Int)
    case searching(done: Int, total: Int)
    case ranking
    case verifying
    case ready
    case failed(String)

    var allowsAnalysisStart: Bool {
        switch self {
        case .idle, .failed, .ready: return true
        default: return false
        }
    }

    var isWorking: Bool {
        switch self {
        case .preparingModel, .transcribing, .mapping, .searching, .ranking, .verifying: return true
        default: return false
        }
    }
}

enum ShortsError: LocalizedError {
    case fileUnavailable
    case tooShort
    case emptyTranscript

    var errorDescription: String? {
        switch self {
        case .fileUnavailable: return "Файл недоступен. Проверь, что видео на месте."
        case .tooShort: return "Видео короче 20 секунд — нарезать нечего."
        case .emptyTranscript: return "Не удалось найти русскую речь в этом видео."
        }
    }
}

enum ShortsExportState: Equatable {
    case idle
    case exporting(done: Int, total: Int, progress: Double)
    case done(URL)
    case failed(String)
}

/// Результат анализа: найденные фрагменты и та же расшифровка,
/// по которой строились их границы. Повторно распознавать исходник
/// для субтитров не нужно.
struct ShortsAnalysisResult: Sendable {
    let candidates: [ShortCandidate]
    let transcript: [TranscriptWord]
}

// MARK: - Контракты обмена с LLM

struct ShortsProposalEnvelope: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let clips: [ShortsProposalDTO]
    enum CodingKeys: String, CodingKey { case schemaVersion = "schema_version", clips }
}

struct ShortsProposalDTO: Codable, Equatable, Sendable {
    let id: String
    let firstWordID: String
    let lastWordID: String
    let title: String
    let reason: String
    let confidence: Double
    /// Первые 5–7 слов ролика — хук для зрителя.
    let hook: String
    /// Вирусный паттерн одним-двумя словами.
    let pattern: String
    /// Тема фрагмента одним-двумя словами.
    let topic: String
    /// Баллы решётки 0–10: цепкость начала, самостоятельность, польза, темп.
    let hookScore: Int
    let standaloneScore: Int
    let payoffScore: Int
    let pacingScore: Int
    enum CodingKeys: String, CodingKey {
        case id, title, reason, confidence, hook, pattern, topic
        case firstWordID = "first_word_id"
        case lastWordID = "last_word_id"
        case hookScore = "hook_score"
        case standaloneScore = "standalone_score"
        case payoffScore = "payoff_score"
        case pacingScore = "pacing_score"
    }
}

extension ShortsProposalDTO {
    /// Ленентный вход: qwen отвечает без строгой JSON-схемы, поэтому новые
    /// поля могут отсутствовать — подставляем нейтральные значения, а баллы
    /// ещё и зажимаем в 0–10 на случай самодеятельности модели.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        firstWordID = try container.decode(String.self, forKey: .firstWordID)
        lastWordID = try container.decode(String.self, forKey: .lastWordID)
        title = try container.decode(String.self, forKey: .title)
        reason = try container.decode(String.self, forKey: .reason)
        confidence = try container.decode(Double.self, forKey: .confidence)
        hook = try container.decodeIfPresent(String.self, forKey: .hook) ?? ""
        pattern = try container.decodeIfPresent(String.self, forKey: .pattern) ?? ""
        topic = try container.decodeIfPresent(String.self, forKey: .topic) ?? ""
        hookScore = Self.clamped(container, key: .hookScore)
        standaloneScore = Self.clamped(container, key: .standaloneScore)
        payoffScore = Self.clamped(container, key: .payoffScore)
        pacingScore = Self.clamped(container, key: .pacingScore)
    }

    private static func clamped(
        _ container: KeyedDecodingContainer<CodingKeys>,
        key: CodingKeys
    ) -> Int {
        let raw = (try? container.decodeIfPresent(Int.self, forKey: key)) ?? 5
        return min(10, max(0, raw))
    }
}

enum ShortsDecision: String, Codable, Sendable { case accept, reject }

struct ShortsRankingEnvelope: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let decisions: [ShortsRankDTO]
    enum CodingKeys: String, CodingKey { case schemaVersion = "schema_version", decisions }
}

struct ShortsRankDTO: Codable, Equatable, Sendable {
    let clipID: String
    let decision: ShortsDecision
    let rank: Int
    let title: String
    let reason: String
    let confidence: Double
    enum CodingKeys: String, CodingKey {
        case decision, rank, title, reason, confidence
        case clipID = "clip_id"
    }
}

/// Сводка кандидата для прохода-отбора: вместо полного транскрипта ИИ видит
/// только метаданные и текст самого фрагмента — вызов остаётся компактным.
struct ShortsRankInput: Codable, Equatable, Sendable {
    let id: String
    let title: String
    let reason: String
    let confidence: Double
    let durationSeconds: Double
    let excerpt: String
    let hook: String
    let pattern: String
    let topic: String
    let hookScore: Int
    let standaloneScore: Int
    let payoffScore: Int
    let pacingScore: Int
    enum CodingKeys: String, CodingKey {
        case id, title, reason, confidence, excerpt, hook, pattern, topic
        case durationSeconds = "duration_seconds"
        case hookScore = "hook_score"
        case standaloneScore = "standalone_score"
        case payoffScore = "payoff_score"
        case pacingScore = "pacing_score"
    }
}

/// Сводка отобранного кандидата для верификационного прохода «тест холодного
/// зрителя»: достаточно текста и баллов, полные границы не нужны.
struct ShortsVerifyInput: Codable, Equatable, Sendable {
    let id: String
    let title: String
    let hook: String
    let pattern: String
    let durationSeconds: Double
    let excerpt: String
    let hookScore: Int
    let standaloneScore: Int
    let payoffScore: Int
    let pacingScore: Int
    enum CodingKeys: String, CodingKey {
        case id, title, hook, pattern, excerpt
        case durationSeconds = "duration_seconds"
        case hookScore = "hook_score"
        case standaloneScore = "standalone_score"
        case payoffScore = "payoff_score"
        case pacingScore = "pacing_score"
    }
}

// MARK: - Карта видео (проход 0)

/// Итог анализа одного окна: о чём кусок и где его сильные места.
struct ShortsMapEnvelope: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let summary: String
    let peaks: [ShortsMapPeakDTO]
    enum CodingKeys: String, CodingKey { case schemaVersion = "schema_version", summary, peaks }
}

struct ShortsMapPeakDTO: Codable, Equatable, Sendable {
    let firstWordID: String
    let lastWordID: String
    let what: String
    enum CodingKeys: String, CodingKey {
        case what
        case firstWordID = "first_word_id"
        case lastWordID = "last_word_id"
    }
}

// MARK: - Верификация (проход 3)

struct ShortsVerdictEnvelope: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let verdicts: [ShortsVerdictDTO]
    enum CodingKeys: String, CodingKey { case schemaVersion = "schema_version", verdicts }
}

struct ShortsVerdictDTO: Codable, Equatable, Sendable {
    let clipID: String
    let keep: Bool
    let verdict: String
    enum CodingKeys: String, CodingKey {
        case keep, verdict
        case clipID = "clip_id"
    }
}
