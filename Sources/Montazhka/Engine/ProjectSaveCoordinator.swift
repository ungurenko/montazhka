import Foundation
import OSLog
import Observation

@MainActor
@Observable
final class ProjectSaveCoordinator {
    /// Чем кончилась запись перед закрытием.
    enum FlushOutcome: Equatable, Sendable {
        case saved
        /// Файл изменил агент: его версия осталась, версия окна легла проектом-копией.
        case keptCopy(name: String)
    }

    private enum WriteResult {
        case saved
        case keptCopy(name: String?)
        case failed(Error)
        case cancelled
    }

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
    /// Сменяется, когда окно принимает версию с диска: записи, поставленные в очередь
    /// раньше, несут снимок прежней версии окна и не должны лечь поверх новой.
    @ObservationIgnored private var lineage = 0
    /// Последняя запись не удалась, а правка окна так и не на диске.
    @ObservationIgnored private var lastWriteFailed = false

    init(repository: any ProjectRepository) {
        self.repository = repository
    }

    var editGeneration: Int { generation.current + lineage }

    /// Правка ждёт отложенной записи.
    var hasPendingSave: Bool { pendingTask != nil }

    /// В окне есть правка, которой нет на диске: ждёт записи или запись не удалась.
    var hasUnsavedChanges: Bool { pendingTask != nil || lastWriteFailed }

    /// Версия, из которой окно показывает проект: та, что вернуло чтение.
    func adopt(_ revision: ProjectRevision?) {
        knownRevision = revision
        hasKnownRevision = true
        lineage += 1
        lastWriteFailed = false
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
        let base = lineage
        pendingTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(500))
                guard let self, !Task.isCancelled else { return }
                await self.persist(project, generation: current, base: base)
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
        await persist(project, generation: current, base: lineage)
    }

    /// Запись перед закрытием: ошибка не прячется в статус, а выбрасывается — закрывать
    /// проект нельзя. Конфликт с правкой агента — не ошибка: версия окна ложится копией.
    func flush(_ project: Project) async throws -> FlushOutcome {
        pendingTask?.cancel()
        pendingTask = nil
        let current = generation.advance()
        status = .saving
        switch await enqueueWrite(project, generation: current, notifyConflict: false, base: lineage) {
        case .saved:
            return .saved
        case .keptCopy(let name?):
            return .keptCopy(name: name)
        case .keptCopy(nil):
            throw ProjectStoreError.conflict
        case .failed(let error):
            throw error
        case .cancelled:
            throw CancellationError()
        }
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

    private func persist(_ project: Project, generation current: Int, base: Int) async {
        if generation.isCurrent(current) { pendingTask = nil }
        _ = await enqueueWrite(project, generation: current, notifyConflict: true, base: base)
    }

    private func enqueueWrite(_ project: Project, generation current: Int, notifyConflict: Bool, base: Int) async
        -> WriteResult
    {
        let previous = lastWrite
        let write = Task { [weak self] () -> WriteResult in
            await previous?.value
            guard let self else { return .cancelled }
            return await self.write(project, base: base, generation: current, notifyConflict: notifyConflict)
        }
        lastWrite = Task { _ = await write.value }
        return await write.value
    }

    /// Сверка версии и запись — одно действие хранилища под общей блокировкой. Снимок
    /// из прежней версии окна (`base` устарел — окно уже приняло версию с диска) — конфликт.
    private func write(
        _ project: Project, base: Int, generation current: Int, notifyConflict: Bool
    ) async -> WriteResult {
        writesInFlight += 1
        defer { writesInFlight -= 1 }
        do {
            guard base == lineage else { throw ProjectStoreError.conflict }
            knownRevision = try await repository.save(project, expected: knownRevision)
            lastWriteFailed = false
            if generation.isCurrent(current) { status = .saved }
            return .saved
        } catch ProjectStoreError.conflict {
            return .keptCopy(name: await keepCopyAfterConflict(project, generation: current, notify: notifyConflict))
        } catch is CancellationError {
            return .cancelled
        } catch {
            Logger.persistence.error("Не удалось сохранить проект: \(error.localizedDescription)")
            lastWriteFailed = true
            if generation.isCurrent(current) { status = .failed(UserFacingError.make(error, context: .project)) }
            return .failed(error)
        }
    }

    /// Чужая правка остаётся на месте, версия окна — копией рядом; окно перечитывает проект.
    /// Не вышла и копия — окно версию не бросает: ошибка видна, перечитывания нет.
    /// Возвращает имя копии; nil — сохранить её не вышло.
    private func keepCopyAfterConflict(_ project: Project, generation current: Int, notify: Bool) async -> String? {
        let copy = Self.recoveryCopy(of: project)
        do {
            try await repository.save(copy)
        } catch {
            Logger.persistence.error("Не удалось сохранить копию версии окна: \(error.localizedDescription)")
            lastWriteFailed = true
            if generation.isCurrent(current) { status = .failed(UserFacingError.make(error, context: .project)) }
            return nil
        }
        lastWriteFailed = false
        if generation.isCurrent(current) { status = .idle }
        if notify { onExternalChange?(copy.name) }
        return copy.name
    }
}
