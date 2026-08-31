import CryptoKit
import Foundation

enum SmartEditModel: String, CaseIterable, Codable, Sendable {
    case qwen = "qwen/qwen3.7-flash"
    case deepSeek = "deepseek/deepseek-v4-flash-0731"
    case luna = "openai/gpt-5.6-luna"

    var title: String {
        switch self {
        case .qwen: return "Qwen 3.7 Flash"
        case .deepSeek: return "DeepSeek V4 Flash"
        case .luna: return "GPT-5.6 Luna"
        }
    }

    static let key = "smartEdit.openRouterModel"

    /// Восстановленное значение из хранилища настроек; по умолчанию — `.qwen`.
    static func saved(in store: any PreferenceStoring = UserDefaultsPreferenceStore.standard) -> SmartEditModel {
        guard let raw = store.string(forKey: key) else { return .qwen }
        return SmartEditModel(rawValue: raw) ?? .qwen
    }

    func save(in store: any PreferenceStoring = UserDefaultsPreferenceStore.standard) {
        store.set(rawValue, forKey: Self.key)
    }

    var usesStrictSchema: Bool { self != .qwen }
}

/// Уровень «размышлений» модели у поддерживаемых ИИ-провайдеров.
enum ReasoningEffort: String, CaseIterable, Codable, Sendable {
    case none, minimal, low, medium, high, xhigh, max, ultra

    static let openRouterCases = allCases.filter { $0 != .ultra }

    var title: String {
        switch self {
        case .none: return "Выкл"
        case .minimal: return "Минимум"
        case .low: return "Низкий"
        case .medium: return "Средний"
        case .high: return "Высокий"
        case .xhigh: return "Очень высокий"
        case .max: return "Максимум"
        case .ultra: return "Ультра"
        }
    }
}

/// Выбор уровня размышлений в UI: «Авто» (параметр reasoning не отправляется —
/// модель использует свой уровень по умолчанию) или явный уровень.
enum ReasoningChoice: Hashable, Identifiable, Sendable {
    case auto
    case effort(ReasoningEffort)

    var id: String {
        switch self {
        case .auto: return "auto"
        case .effort(let effort): return effort.rawValue
        }
    }

    var title: String {
        switch self {
        case .auto: return "Авто"
        case .effort(let effort): return effort.title
        }
    }

    /// Значение для API: nil — не отправлять reasoning вовсе.
    var apiEffort: String? {
        switch self {
        case .auto: return nil
        case .effort(let effort): return effort.rawValue
        }
    }

    static func saved(key: String, in store: any PreferenceStoring = UserDefaultsPreferenceStore.standard)
        -> ReasoningChoice
    {
        guard let raw = store.string(forKey: key), raw != "auto",
            let effort = ReasoningEffort(rawValue: raw)
        else { return .auto }
        return .effort(effort)
    }

    func save(key: String, in store: any PreferenceStoring = UserDefaultsPreferenceStore.standard) {
        store.set(id, forKey: key)
    }

    /// Варианты пикера по возможностям модели: «Авто» всегда, дальше уровни,
    /// которые модель принимает (nil — все значения OpenRouter).
    /// «Выкл» прячется у моделей с обязательными размышлениями.
    static func options(availableEfforts: [ReasoningEffort]?, mandatory: Bool) -> [ReasoningChoice] {
        let efforts = availableEfforts ?? ReasoningEffort.openRouterCases
        var choices: [ReasoningChoice] = [.auto]
        for effort in ReasoningEffort.allCases {
            guard efforts.contains(effort), !(effort == .none && mandatory) else { continue }
            choices.append(.effort(effort))
        }
        return choices
    }
}

enum SmartEditKind: String, Codable, CaseIterable, Sendable {
    case fillerSound = "filler_sound"
    case falseStart = "false_start"
    case selfCorrection = "self_correction"
    case duplicateTake = "duplicate_take"
    case semanticRepeat = "semantic_repeat"

    var title: String {
        switch self {
        case .fillerSound: return "Звук-паразит"
        case .falseStart: return "Фальстарт"
        case .selfCorrection: return "Самоисправление"
        case .duplicateTake: return "Дубль"
        case .semanticRepeat: return "Смысловой повтор"
        }
    }

    var mayEnableAutomatically: Bool { self != .semanticRepeat }
}

struct SmartEditCandidate: Identifiable, Equatable, Sendable {
    let id: UUID
    let kind: SmartEditKind
    let reason: String
    let originalText: String
    let timelineStart: Double
    let timelineEnd: Double
    let confidence: Double
    var enabled: Bool

    var duration: Double { max(0, timelineEnd - timelineStart) }
}

enum SmartEditStatus: Equatable {
    case idle
    case preparingModel(progress: Double?)
    case transcribing(done: Int, total: Int, progress: Double?)
    case proposing
    case reviewing
    case preparingCuts
    case ready
    case failed(String)

    var allowsAnalysisStart: Bool {
        switch self {
        case .idle, .failed: return true
        default: return false
        }
    }
}

struct SmartEditSnapshot: Equatable, Sendable {
    let id: String
    let clips: [Clip]

    init(clips: [Clip]) {
        self.clips = clips
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(clips)) ?? Data()
        id = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

enum SmartEditDecision: String, Codable, Sendable { case accept, reject }

struct SmartEditAnalysisResult: Sendable {
    let snapshot: SmartEditSnapshot
    let candidates: [SmartEditCandidate]
}

enum SmartEditError: LocalizedError {
    case emptyTranscript
    case staleAnalysis

    var errorDescription: String? {
        switch self {
        case .emptyTranscript: return "Не удалось найти речь в видимой части монтажа."
        case .staleAnalysis: return "Монтаж изменился. Запусти анализ ещё раз."
        }
    }
}

enum SmartEditRanges {
    static func merged(_ ranges: [(start: Double, end: Double)]) -> [(start: Double, end: Double)] {
        let sorted = ranges.filter { $0.end > $0.start }.sorted { $0.start < $1.start }
        var result: [(start: Double, end: Double)] = []
        for range in sorted {
            if let last = result.last, range.start < last.end {
                result[result.count - 1].end = max(last.end, range.end)
            } else {
                result.append(range)
            }
        }
        return result
    }
}

enum SmartEditSelection {
    static func shouldEnable(
        kind: SmartEditKind, confidence: Double,
        hasSafeBoundary: Bool
    ) -> Bool {
        hasSafeBoundary && confidence >= 0.90 && kind.mayEnableAutomatically
    }
}

enum SmartEditPlatform {
    static var isSupported: Bool {
        #if arch(arm64)
            true
        #else
            false
        #endif
    }
}
