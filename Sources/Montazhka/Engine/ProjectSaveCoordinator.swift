import Foundation
import OSLog
import Observation

@MainActor
@Observable
final class ProjectSaveCoordinator {
    private(set) var status: ProjectSaveStatus = .idle

    /// Своя запись не прошла: файл на диске успел изменить кто-то другой (агент).
    /// Окно должно перечитать проект, а не затирать чужую правку. Аргумент — имя
    /// проекта-копии, куда легла версия окна; nil — копию сохранить не вышло.
    @ObservationIgnored var onExternalChange: ((String?) -> Void)?

    private let repository: any ProjectRepository
    @ObservationIgnored private var pendingTask: Task<Void, Never>?
    @ObservationIgnored private var generation = Generation()
    /// Версия файла, которую окно видело последней: после загрузки или своей записи.
    @ObservationIgnored private var knownRevision: ProjectRevision?
    @ObservationIgnored private var hasKnownRevision = false
    @ObservationIgnored private var writesInFlight = 0
    /// Записи идут строго друг за другом: иначе вторая сверялась бы с версией,
    /// которую только что сменила первая, и получала бы ложный конфликт.
    @ObservationIgnored private var lastWrite: Task<Void, Never>?

    init(repository: any ProjectRepository) {
        self.repository = repository
    }

    /// Правка ждёт отложенной записи.
    var hasPendingSave: Bool { pendingTask != nil }

    /// Версия, из которой окно показывает проект: та, что вернуло чтение или своя запись.
    func adopt(_ revision: ProjectRevision?) {
        knownRevision = revision
        hasKnownRevision = true
    }

    /// Запомнить текущую версию файла как «свою». Только когда версии из чтения нет:
    /// между чтением и этим вызовом файл мог смениться.
    func adoptDiskRevision(for id: UUID) {
        adopt(repository.revision(of: id))
    }

    /// Файл на диске изменил кто-то другой. Пока идёт своя запись, ответ всегда «нет»:
    /// новая версия своей записи ещё не запомнена.
    func diskChangedElsewhere(for id: UUID) -> Bool {
        guard writesInFlight == 0, hasKnownRevision else { return false }
        return repository.revision(of: id) != knownRevision
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
        do {
            adopt(try repository.saveBeforeTermination(project, expected: knownRevision))
            status = .saved
        } catch ProjectStoreError.conflict {
            // Своя незаконченная запись тоже даёт конфликт — тогда копия лишняя, но ничего не теряется.
            let copy = Self.recoveryCopy(of: project)
            do {
                _ = try repository.saveBeforeTermination(copy, expected: nil)
                Logger.persistence.info("Проект изменён снаружи — версия окна сохранена копией при завершении.")
            } catch {
                Logger.persistence.error("Не удалось сохранить копию при завершении: \(error.localizedDescription)")
                status = .failed(UserFacingError.make(error, context: .project))
            }
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

    /// Версия окна, которую не удалось записать поверх чужой правки: отдельный проект
    /// в списке — переживает перезапуск. У копии черновика шортса свой MP4.
    static func recoveryCopy(of project: Project, at date: Date = Date()) -> Project {
        var copy = project
        copy.id = UUID()
        let time = date.formatted(
            Date.FormatStyle().hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).locale(Locale(identifier: "ru_RU")))
        copy.name = "\(project.name) — версия окна \(time)"
        copy.createdAt = date
        copy.updatedAt = date
        if let path = copy.shorts?.exportPath {
            copy.shorts?.exportPath = ShortsExporter.copyURL(for: URL(fileURLWithPath: path)).path
        }
        return copy
    }

    private func persist(_ project: Project, generation current: Int) async {
        if generation.isCurrent(current) { pendingTask = nil }
        let previous = lastWrite
        let write = Task { [weak self] in
            await previous?.value
            await self?.write(project, generation: current)
        }
        lastWrite = write
        await write.value
    }

    /// Сверка версии и запись — одно действие хранилища под общей блокировкой.
    private func write(_ project: Project, generation current: Int) async {
        writesInFlight += 1
        defer { writesInFlight -= 1 }
        do {
            adopt(try await repository.save(project, expected: knownRevision))
            guard generation.isCurrent(current) else { return }
            status = .saved
        } catch ProjectStoreError.conflict {
            await keepCopyAfterConflict(project, generation: current)
        } catch is CancellationError {
            return
        } catch {
            guard generation.isCurrent(current) else { return }
            Logger.persistence.error("Не удалось сохранить проект: \(error.localizedDescription)")
            status = .failed(UserFacingError.make(error, context: .project))
        }
    }

    /// Чужая правка остаётся на месте, версия окна — копией рядом; окно перечитывает проект.
    private func keepCopyAfterConflict(_ project: Project, generation current: Int) async {
        let copy = Self.recoveryCopy(of: project)
        var copyName: String?
        do {
            try await repository.save(copy)
            copyName = copy.name
        } catch {
            Logger.persistence.error("Не удалось сохранить копию версии окна: \(error.localizedDescription)")
        }
        if generation.isCurrent(current) { status = .idle }
        onExternalChange?(copyName)
    }
}
