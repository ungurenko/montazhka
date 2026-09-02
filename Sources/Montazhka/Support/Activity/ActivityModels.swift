import Foundation

/// Виды длительной работы. Каждый вид может идти только в одном экземпляре:
/// нельзя одновременно два экспорта или два анализа речи.
enum ActivityKind: String, CaseIterable, Sendable {
    case clipImport
    case previewPrepare
    case pauseDetect
    case smartEdit
    case voiceEnhance
    case shortsAnalysis
    case export
    case shortsExport

    /// Что показать первым, если работа идёт сразу в двух местах.
    /// Сохранение файла важнее фонового пересчёта превью.
    var priority: Int {
        switch self {
        case .export, .shortsExport: return 100
        case .smartEdit, .shortsAnalysis: return 60
        case .voiceEnhance, .pauseDetect: return 40
        case .clipImport: return 30
        case .previewPrepare: return 10
        }
    }

    /// О коротких служебных операциях Док сообщать не нужно —
    /// они заканчиваются раньше, чем пользователь успеет отвести взгляд.
    var deservesAttention: Bool {
        switch self {
        case .previewPrepare, .pauseDetect, .clipImport: return false
        default: return true
        }
    }
}

/// Насколько работа продвинулась.
enum ActivityProgress: Equatable, Sendable {
    /// Честное «пока не знаю»: так выглядит ожидание ответа модели.
    case indeterminate
    /// Реальная доля от нуля до единицы, взятая из источника работы.
    case fraction(Double)

    var value: Double? {
        if case .fraction(let value) = self { return min(max(value, 0), 1) }
        return nil
    }
}

/// Один шаг многоэтапной работы.
struct ActivityStage: Equatable, Sendable {
    /// Устойчивый ключ — под ним копится память о типичной длительности.
    let id: String
    let title: String
}

/// Снимок состояния работы, собранный из статуса контроллера.
struct ActivitySnapshot: Equatable, Sendable {
    let stageIndex: Int
    let caption: String
    let progress: ActivityProgress
}

/// Идущая работа в том виде, в котором её показывают пользователю.
struct Activity: Identifiable, Equatable, Sendable {
    var id: ActivityKind { kind }
    let kind: ActivityKind
    var title: String
    var stages: [ActivityStage]
    var stageIndex: Int
    var caption: String
    var progress: ActivityProgress
    var isCancellable: Bool
    let startedAt: Date
    var stageStartedAt: Date
    /// Сколько осталось. `nil` — оценка ещё не заслуживает доверия,
    /// и тогда лучше не показывать ничего, чем показать выдуманное число.
    var estimatedRemaining: TimeInterval?
    /// Сколько этот шаг занимал в прошлые разы. `nil` при первом запуске.
    var typicalStageDuration: TimeInterval?

    var currentStage: ActivityStage? {
        stages.indices.contains(stageIndex) ? stages[stageIndex] : nil
    }

    /// Шаг идёт заметно дольше обычного — стоит сказать об этом прямо,
    /// чтобы не выглядело зависанием.
    func isSlowerThanUsual(now: Date) -> Bool {
        guard let typical = typicalStageDuration, typical > 0 else { return false }
        return now.timeIntervalSince(stageStartedAt) > typical * 1.5
    }
}

/// Чем закончилась работа.
enum ActivityOutcome: Equatable, Sendable {
    case success(String)
    case failure(String)
    case cancelled
}

/// Завершённая работа — для значка в Доке, звука и итоговой плашки.
struct ActivityCompletion: Equatable, Sendable {
    let kind: ActivityKind
    let outcome: ActivityOutcome
    let duration: TimeInterval
    let finishedAt: Date
}
