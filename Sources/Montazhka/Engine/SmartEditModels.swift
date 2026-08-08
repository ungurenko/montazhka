import Foundation
import CryptoKit

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

    static var saved: SmartEditModel {
        get {
            guard let raw = UserDefaults.standard.string(forKey: "smartEdit.openRouterModel") else {
                return .qwen
            }
            return SmartEditModel(rawValue: raw) ?? .qwen
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "smartEdit.openRouterModel") }
    }

    var usesStrictSchema: Bool { self != .qwen }
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

struct SmartEditProposal: Equatable, Sendable {
    let id: String
    let kind: SmartEditKind
    let firstWordID: String
    let lastWordID: String
    let reason: String
    let confidence: Double
}

struct SmartEditReview: Equatable, Sendable {
    enum Decision: String, Codable, Sendable { case accept, reject }
    let editID: String
    let decision: Decision
    let firstWordID: String
    let lastWordID: String
    let reason: String
    let confidence: Double
}

struct SmartEditAnalysisResult: Sendable {
    let snapshot: SmartEditSnapshot
    let candidates: [SmartEditCandidate]
}

enum SmartEditError: LocalizedError {
    case emptyTranscript
    case staleAnalysis
    case invalidResponse
    case noSafeCandidates

    var errorDescription: String? {
        switch self {
        case .emptyTranscript: return "Не удалось найти речь в видимой части монтажа."
        case .staleAnalysis: return "Монтаж изменился. Запусти анализ ещё раз."
        case .invalidResponse: return "ИИ вернул повреждённый ответ. Попробуй ещё раз."
        case .noSafeCandidates: return "Речь уже звучит чисто — надёжных вырезок не нашёл."
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
    static func shouldEnable(kind: SmartEditKind, confidence: Double,
                             hasSafeBoundary: Bool) -> Bool {
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
