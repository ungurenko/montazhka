import Foundation

/// Проверка честности сообщений о ходе работы: нет ли выдуманных чисел,
/// молчит ли оценка времени, пока не уверена, и снимается ли работа с учёта.
enum ActivitySelfTest {
    /// Хранилище настроек в памяти: самопроверка не должна трогать
    /// настоящие настройки пользователя.
    private final class MemoryPreferences: PreferenceStoring, @unchecked Sendable {
        private var values: [String: String] = [:]
        private var flags: [String: Bool] = [:]
        func string(forKey key: String) -> String? { values[key] }
        func set(_ value: String?, forKey key: String) { values[key] = value }
        func bool(forKey key: String) -> Bool { flags[key] ?? false }
        func set(_ value: Bool, forKey key: String) { flags[key] = value }
    }

    @MainActor
    static func run() async -> Int {
        print("Сообщения о ходе работы:")
        var failures = 0

        func check(_ condition: Bool, _ label: String) {
            if condition {
                print("  ✓ \(label)")
            } else {
                failures += 1
                print("  ✗ ПРОВАЛ: \(label)")
            }
        }

        checkNoInventedProgress(check)
        checkEstimatorStaysSilent(check)
        checkEstimatorSpeaksWhenSure(check)
        checkStageMemory(check)
        checkLifecycle(check)
        checkApproximateWording(check)

        return failures
    }

    /// Ожидание ответа модели не имеет доли выполнения — и не должно её выдумывать.
    private static func checkNoInventedProgress(_ check: (Bool, String) -> Void) {
        let waiting: [SmartEditStatus] = [.proposing, .reviewing, .preparingCuts]
        check(
            waiting.allSatisfy { $0.activitySnapshot?.progress == .indeterminate },
            "ожидание модели не изображает прогресс")
        check(
            [ShortsStatus.ranking, .verifying].allSatisfy {
                $0.activitySnapshot?.progress == .indeterminate
            },
            "отбор моментов не изображает прогресс")
        check(
            SmartEditStatus.idle.activitySnapshot == nil
                && SmartEditStatus.ready.activitySnapshot == nil
                && SmartEditStatus.failed("нет").activitySnapshot == nil,
            "завершённые состояния не считаются работой")
        check(
            SmartEditStatus.transcribing(done: 1, total: 4, progress: nil)
                .activitySnapshot?.progress == .fraction(0.25),
            "расшифровка отдаёт настоящую долю")
        check(
            ShortsStatus.mapping(done: 0, total: 0).activitySnapshot?.progress == .indeterminate,
            "деление на ноль окон не даёт ложной доли")
    }

    private static func checkEstimatorStaysSilent(_ check: (Bool, String) -> Void) {
        var estimator = RemainingTimeEstimator()
        let start = Date()
        let first = estimator.record(fraction: 0.1, now: start)
        let second = estimator.record(fraction: 0.2, now: start.addingTimeInterval(1))
        let third = estimator.record(fraction: 0.3, now: start.addingTimeInterval(2))
        check(
            first == nil && second == nil && third == nil,
            "первые секунды оценка молчит, а не гадает")
    }

    private static func checkEstimatorSpeaksWhenSure(_ check: (Bool, String) -> Void) {
        var estimator = RemainingTimeEstimator()
        let start = Date()
        var estimate: TimeInterval?
        // Ровная скорость: 10 % за 10 секунд, значит на остаток нужно ещё столько же.
        for step in 0...5 {
            estimate = estimator.record(
                fraction: Double(step) * 0.1,
                now: start.addingTimeInterval(Double(step) * 10))
        }
        check(estimate != nil, "при ровной скорости оценка появляется")
        if let estimate {
            check(abs(estimate - 50) < 5, "оценка совпадает со скоростью (получено \(Int(estimate)) сек)")
        }

        var backwards = RemainingTimeEstimator()
        for step in 0...5 {
            _ = backwards.record(fraction: Double(step) * 0.1, now: start.addingTimeInterval(Double(step) * 10))
        }
        let afterRestart = backwards.record(fraction: 0.0, now: start.addingTimeInterval(61))
        check(afterRestart == nil, "перезапуск работы сбрасывает старую оценку")
    }

    private static func checkStageMemory(_ check: (Bool, String) -> Void) {
        let memory = StageDurationMemory(store: MemoryPreferences())
        check(memory.typicalDuration(forStage: "тест") == nil, "без истории о времени не врём")
        for value in [10.0, 40.0, 30.0] {
            memory.remember(value, forStage: "тест")
        }
        check(
            memory.typicalDuration(forStage: "тест") == 30,
            "типичное время — медиана прошлых запусков")
    }

    @MainActor
    private static func checkLifecycle(_ check: (Bool, String) -> Void) {
        let center = ActivityCenter(stageMemory: StageDurationMemory(store: MemoryPreferences()))
        var cancelled = false
        center.begin(
            .smartEdit,
            title: "Умный монтаж речи",
            stages: ActivityStagePlan.smartEdit,
            isCancellable: true,
            cancel: { cancelled = true })
        check(center.primary?.kind == .smartEdit, "начатая работа попадает в центр")

        center.apply(.smartEdit, snapshot: SmartEditStatus.reviewing.activitySnapshot)
        check(center.activity(.smartEdit)?.stageIndex == 3, "центр знает текущий шаг")

        center.begin(.export, title: "Сохранение видео", stages: ActivityStagePlan.export)
        check(center.primary?.kind == .export, "сохранение файла важнее анализа")

        center.cancel(.smartEdit)
        check(cancelled, "отмена доходит до того, кто умеет останавливаться")

        center.finish(.smartEdit, outcome: .cancelled)
        center.finish(.export, outcome: .success("Видео сохранено"))
        check(!center.isBusy, "завершённые работы уходят из центра")
        check(
            center.lastCompletion?.kind == .export,
            "итог последней работы сохраняется для значка в Доке")
        center.acknowledge()
        check(center.lastCompletion == nil, "увиденный итог сбрасывается")
    }

    private static func checkApproximateWording(_ check: (Bool, String) -> Void) {
        check(TimeFormat.approximate(4) == "меньше 10 секунд", "секунды не показываем с точностью до одной")
        check(TimeFormat.approximate(43) == "около 45 секунд", "меньше минуты округляем до пяти секунд")
        check(TimeFormat.approximate(125) == "около 2 мин", "минуты округляем до получаса")
    }
}
