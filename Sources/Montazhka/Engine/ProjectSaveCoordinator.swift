import Foundation
import OSLog
import Observation

@MainActor
@Observable
final class ProjectSaveCoordinator {
    private(set) var status: ProjectSaveStatus = .idle

    /// Сохранение не записало проект: файл на диске успел изменить кто-то
    /// другой (агент). Окно должно перечитать проект, а не затирать чужую правку.
    @ObservationIgnored var onExternalChange: (() -> Void)?

    private let repository: any ProjectRepository
    @ObservationIgnored private var pendingTask: Task<Void, Never>?
    @ObservationIgnored private var generation = Generation()
    /// Версия файла, которую окно видело последней: после загрузки или своей записи.
    @ObservationIgnored private var knownStamp: Date?
    @ObservationIgnored private var writesInFlight = 0

    init(repository: any ProjectRepository) {
        self.repository = repository
    }

    /// Правка ждёт отложенной записи.
    var hasPendingSave: Bool { pendingTask != nil }

    /// Запомнить текущую версию файла как «свою» — после открытия или перечитывания проекта.
    func adoptDiskStamp(for id: UUID) {
        knownStamp = repository.diskStamp(of: id)
    }

    /// Файл на диске изменил кто-то другой. Пока идёт своя запись, ответ всегда «нет»:
    /// новая отметка своей записи ещё не запомнена.
    func diskChangedElsewhere(for id: UUID) -> Bool {
        guard writesInFlight == 0, let knownStamp else { return false }
        return repository.diskStamp(of: id) != knownStamp
    }

    func schedule(_ project: Project) {
        pendingTask?.cancel()
        let current = generation.advance()
        status = .saving
        pendingTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(500))
                guard let self, !Task.isCancelled else { return }
                await self.persist(project, generation: current)
            } catch is CancellationError {
                return
            } catch {
                return
            }
        }
    }

    func saveNow(_ project: Project) async {
        pendingTask?.cancel()
        pendingTask = nil
        let current = generation.advance()
        status = .saving
        await persist(project, generation: current)
    }

    func saveBeforeTermination(_ project: Project) {
        pendingTask?.cancel()
        pendingTask = nil
        _ = generation.advance()
        guard !diskChangedElsewhere(for: project.id) else {
            Logger.persistence.info("Проект изменён снаружи — при завершении не перезаписываю его.")
            return
        }
        do {
            try repository.saveBeforeTermination(project)
            status = .saved
        } catch {
            Logger.persistence.error("Не удалось сохранить проект при завершении: \(error.localizedDescription)")
            status = .failed(UserFacingError.make(error, context: .project))
        }
    }

    func cancelPending() {
        pendingTask?.cancel()
        pendingTask = nil
        _ = generation.advance()
    }

    func dismissError() {
        if case .failed = status { status = .idle }
    }

    private func persist(_ project: Project, generation current: Int) async {
        if generation.isCurrent(current) { pendingTask = nil }
        guard !diskChangedElsewhere(for: project.id) else {
            if generation.isCurrent(current) { status = .idle }
            onExternalChange?()
            return
        }
        writesInFlight += 1
        defer { writesInFlight -= 1 }
        do {
            try await repository.save(project)
            knownStamp = repository.diskStamp(of: project.id)
            guard generation.isCurrent(current) else { return }
            status = .saved
        } catch is CancellationError {
            return
        } catch {
            guard generation.isCurrent(current) else { return }
            Logger.persistence.error("Не удалось сохранить проект: \(error.localizedDescription)")
            status = .failed(UserFacingError.make(error, context: .project))
        }
    }
}
