import Foundation
import Observation

/// Одно место, куда стекается вся длительная работа приложения.
///
/// До него каждая панель сообщала о своей работе сама, поэтому вне этой
/// панели ничего не было видно: закрыл инспектор — и не знаешь, идёт ли
/// анализ. Центр знает обо всём сразу, поэтому его может показать и верхняя
/// панель, и значок в Доке.
@MainActor
@Observable
final class ActivityCenter {
    static let shared = ActivityCenter()

    /// Всё, что идёт прямо сейчас.
    private(set) var activities: [Activity] = []
    /// Чем закончилась последняя работа — пока пользователь это не увидел.
    private(set) var lastCompletion: ActivityCompletion?

    @ObservationIgnored private var cancelHandlers: [ActivityKind: () -> Void] = [:]
    @ObservationIgnored private var estimators: [ActivityKind: RemainingTimeEstimator] = [:]
    @ObservationIgnored private let stageMemory: StageDurationMemory
    @ObservationIgnored private let clock: () -> Date
    @ObservationIgnored private let announcer: ActivityAnnouncer

    init(
        stageMemory: StageDurationMemory = StageDurationMemory(),
        announcer: ActivityAnnouncer = ActivityAnnouncer(),
        clock: @escaping () -> Date = { Date() }
    ) {
        self.stageMemory = stageMemory
        self.announcer = announcer
        self.clock = clock
    }

    /// Самая важная из идущих работ.
    var primary: Activity? {
        activities.max { $0.kind.priority < $1.kind.priority }
    }

    var isBusy: Bool { !activities.isEmpty }

    func activity(_ kind: ActivityKind) -> Activity? {
        activities.first { $0.kind == kind }
    }

    // MARK: - Ход работы

    /// Начинает работу. Повторный вызов для того же вида перезапускает её.
    func begin(
        _ kind: ActivityKind,
        title: String,
        stages: [ActivityStage] = [],
        isCancellable: Bool = false,
        cancel: (() -> Void)? = nil
    ) {
        let now = clock()
        let activity = Activity(
            kind: kind,
            title: title,
            stages: stages,
            stageIndex: 0,
            caption: stages.first?.title ?? title,
            progress: .indeterminate,
            isCancellable: isCancellable,
            startedAt: now,
            stageStartedAt: now,
            estimatedRemaining: nil,
            typicalStageDuration: stages.first.flatMap { stageMemory.typicalDuration(forStage: $0.id) })
        activities.removeAll { $0.kind == kind }
        activities.append(activity)
        estimators[kind] = RemainingTimeEstimator()
        cancelHandlers[kind] = cancel
        if lastCompletion?.kind == kind { lastCompletion = nil }
        announcer.render(primary: primary)
    }

    /// Главный вход для контроллеров: снимок статуса или `nil`, если работа
    /// больше не идёт. Так контроллеры не переписывают свои перечисления —
    /// они только рассказывают о себе.
    func apply(_ kind: ActivityKind, snapshot: ActivitySnapshot?) {
        guard let snapshot else { return }
        guard let index = activities.firstIndex(where: { $0.kind == kind }) else { return }

        let now = clock()
        var activity = activities[index]

        if snapshot.stageIndex != activity.stageIndex {
            rememberStageDuration(of: activity, endingAt: now)
            activity.stageIndex = snapshot.stageIndex
            activity.stageStartedAt = now
            activity.typicalStageDuration = activity.currentStage
                .flatMap { stageMemory.typicalDuration(forStage: $0.id) }
            estimators[kind] = RemainingTimeEstimator()
        }

        activity.caption = snapshot.caption
        activity.progress = snapshot.progress

        if let fraction = snapshot.progress.value {
            activity.estimatedRemaining = estimators[kind]?.record(fraction: fraction, now: now)
        } else {
            activity.estimatedRemaining = nil
        }

        activities[index] = activity
        announcer.render(primary: primary)
    }

    /// Завершает работу и запоминает исход для значка в Доке и звука.
    func finish(_ kind: ActivityKind, outcome: ActivityOutcome) {
        guard let index = activities.firstIndex(where: { $0.kind == kind }) else { return }
        let activity = activities[index]
        let now = clock()

        if case .success = outcome {
            rememberStageDuration(of: activity, endingAt: now)
        }

        activities.remove(at: index)
        estimators[kind] = nil
        cancelHandlers[kind] = nil
        let completion = ActivityCompletion(
            kind: kind,
            outcome: outcome,
            duration: now.timeIntervalSince(activity.startedAt),
            finishedAt: now)
        lastCompletion = completion
        // Пока идёт что-то ещё, значок в Доке продолжает показывать ход работы,
        // а не итог только что закончившейся.
        if let next = primary {
            announcer.render(primary: next)
        } else {
            announcer.announce(completion)
        }
    }

    /// Просит работу остановиться. Сам факт остановки придёт через `finish`.
    func cancel(_ kind: ActivityKind) {
        cancelHandlers[kind]?()
    }

    /// Пользователь увидел итог — значок в Доке больше не нужен.
    func acknowledge() {
        lastCompletion = nil
        announcer.acknowledge()
    }

    private func rememberStageDuration(of activity: Activity, endingAt now: Date) {
        guard let stage = activity.currentStage else { return }
        stageMemory.remember(now.timeIntervalSince(activity.stageStartedAt), forStage: stage.id)
    }
}
