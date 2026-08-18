import Foundation

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

    static var saved: ShortsCount {
        get {
            guard let raw = UserDefaults.standard.string(forKey: "shorts.count") else { return .five }
            return ShortsCount(rawValue: raw) ?? .five
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "shorts.count") }
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
    let excerpt: String
    let start: Double
    let end: Double
    let confidence: Double
    var enabled: Bool

    var duration: Double { max(0, end - start) }
}

enum ShortsStatus: Equatable {
    case idle
    case preparingModel(progress: Double?)
    case transcribing(progress: Double?)
    case searching(done: Int, total: Int)
    case ranking
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
        case .preparingModel, .transcribing, .searching, .ranking: return true
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
    enum CodingKeys: String, CodingKey {
        case id, title, reason, confidence
        case firstWordID = "first_word_id"
        case lastWordID = "last_word_id"
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
    enum CodingKeys: String, CodingKey {
        case id, title, reason, confidence, excerpt
        case durationSeconds = "duration_seconds"
    }
}
