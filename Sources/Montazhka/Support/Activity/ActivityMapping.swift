import Foundation

/// Планы этапов: что именно программа делает и в каком порядке.
///
/// Пользователю показывают «шаг 4 из 6» — это правда всегда, в отличие от
/// прежней шкалы, которая на трёх последних шагах стояла на 0,68, 0,82 и 0,94.
enum ActivityStagePlan {
    static let smartEdit: [ActivityStage] = [
        ActivityStage(id: "smartEdit.model", title: "Локальная модель"),
        ActivityStage(id: "smartEdit.transcribe", title: "Расшифровка речи"),
        ActivityStage(id: "smartEdit.propose", title: "Поиск оговорок"),
        ActivityStage(id: "smartEdit.review", title: "Проверка редактором"),
        ActivityStage(id: "smartEdit.cuts", title: "Границы склеек"),
    ]

    static let shorts: [ActivityStage] = [
        ActivityStage(id: "shorts.model", title: "Локальная модель"),
        ActivityStage(id: "shorts.transcribe", title: "Расшифровка речи"),
        ActivityStage(id: "shorts.map", title: "Карта видео"),
        ActivityStage(id: "shorts.search", title: "Поиск моментов"),
        ActivityStage(id: "shorts.rank", title: "Отбор лучших"),
        ActivityStage(id: "shorts.verify", title: "Проверка"),
    ]

    static let export: [ActivityStage] = [
        ActivityStage(id: "export.prepare", title: "Подготовка"),
        ActivityStage(id: "export.write", title: "Запись файла"),
    ]

    static let shortsExport: [ActivityStage] = [
        ActivityStage(id: "shortsExport.write", title: "Запись роликов")
    ]
}

/// Доля внутри шага: сколько сделано из скольких.
private func stepFraction(done: Int, total: Int, inner: Double = 0) -> ActivityProgress {
    guard total > 0 else { return .indeterminate }
    return .fraction((Double(done) + inner) / Double(total))
}

extension SmartEditStatus {
    /// Снимок для центра активности. `nil` — работа не идёт.
    ///
    /// Здесь же живут тексты статусов: раньше они дублировались во вью,
    /// и панель знала о ходе работы больше, чем сама программа.
    var activitySnapshot: ActivitySnapshot? {
        switch self {
        case .preparingModel(let progress):
            return ActivitySnapshot(
                stageIndex: 0,
                caption: "Готовлю локальную модель — в первый раз загружается около 460 МБ",
                progress: progress.map { ActivityProgress.fraction($0) } ?? .indeterminate)
        case .transcribing(let done, let total, let progress):
            return ActivitySnapshot(
                stageIndex: 1,
                caption: "Расшифровываю речь: \(done) из \(total)",
                progress: stepFraction(done: done, total: total, inner: progress ?? 0))
        case .proposing:
            return ActivitySnapshot(
                stageIndex: 2,
                caption: "Монтажёр ищет оговорки и дубли",
                progress: .indeterminate)
        case .reviewing:
            return ActivitySnapshot(
                stageIndex: 3,
                caption: "Редактор проверяет смысл и естественность",
                progress: .indeterminate)
        case .preparingCuts:
            return ActivitySnapshot(
                stageIndex: 4,
                caption: "Ищу тихие границы для склеек",
                progress: .indeterminate)
        case .idle, .ready, .failed:
            return nil
        }
    }
}

extension ShortsStatus {
    var activitySnapshot: ActivitySnapshot? {
        switch self {
        case .preparingModel(let progress):
            return ActivitySnapshot(
                stageIndex: 0,
                caption: "Готовлю локальную модель — в первый раз загружается около 460 МБ",
                progress: progress.map { ActivityProgress.fraction($0) } ?? .indeterminate)
        case .transcribing(let progress):
            return ActivitySnapshot(
                stageIndex: 1,
                caption: "Расшифровываю речь",
                progress: progress.map { ActivityProgress.fraction($0) } ?? .indeterminate)
        case .mapping(let done, let total):
            return ActivitySnapshot(
                stageIndex: 2,
                caption: "Составляю карту видео: окно \(done + 1) из \(total)",
                progress: stepFraction(done: done, total: total))
        case .searching(let done, let total):
            return ActivitySnapshot(
                stageIndex: 3,
                caption: "Ищу сильные моменты: окно \(done + 1) из \(total)",
                progress: stepFraction(done: done, total: total))
        case .ranking:
            return ActivitySnapshot(
                stageIndex: 4,
                caption: "Отбираю и ранжирую лучшие моменты",
                progress: .indeterminate)
        case .verifying:
            return ActivitySnapshot(
                stageIndex: 5,
                caption: "Проверяю выбранные моменты тестом холодного зрителя",
                progress: .indeterminate)
        case .idle, .ready, .failed:
            return nil
        }
    }
}

extension ShortsExportState {
    var activitySnapshot: ActivitySnapshot? {
        guard case .exporting(let done, let total, let progress) = self else { return nil }
        return ActivitySnapshot(
            stageIndex: 0,
            caption: "Сохраняю ролик \(min(done + 1, total)) из \(total)",
            progress: stepFraction(done: done, total: total, inner: progress))
    }
}
