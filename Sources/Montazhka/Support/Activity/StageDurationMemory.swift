import Foundation

/// Память о том, сколько шаг занимал в прошлые разы.
///
/// Нужна там, где реального прогресса нет: пока модель думает, честно
/// сказать «обычно около 40 секунд» можно только по собственной истории.
/// В первый раз истории нет — и тогда не говорим ничего.
struct StageDurationMemory {
    /// Сколько последних запусков помним. Медиана пяти устойчива к одному
    /// выбросу и при этом быстро подстраивается под новый компьютер или модель.
    private let capacity = 5
    private let store: any PreferenceStoring

    init(store: any PreferenceStoring = UserDefaultsPreferenceStore.standard) {
        self.store = store
    }

    /// Типичная длительность шага или `nil`, если запусков ещё не было.
    func typicalDuration(forStage id: String) -> TimeInterval? {
        let history = durations(forStage: id)
        guard !history.isEmpty else { return nil }
        let sorted = history.sorted()
        return sorted[sorted.count / 2]
    }

    /// Запоминает длительность удачно завершённого шага.
    /// Отменённые и упавшие шаги не запоминаем — они портят медиану.
    func remember(_ duration: TimeInterval, forStage id: String) {
        guard duration.isFinite, duration > 0.5 else { return }
        var history = durations(forStage: id)
        history.append(duration)
        if history.count > capacity {
            history.removeFirst(history.count - capacity)
        }
        let encoded = history.map { String(format: "%.1f", $0) }.joined(separator: ",")
        store.set(encoded, forKey: Self.key(for: id))
    }

    private func durations(forStage id: String) -> [TimeInterval] {
        guard let raw = store.string(forKey: Self.key(for: id)) else { return [] }
        return raw.split(separator: ",").compactMap { Double($0) }.filter { $0 > 0 }
    }

    private static func key(for id: String) -> String {
        "activity.stage.\(id).durations"
    }
}
