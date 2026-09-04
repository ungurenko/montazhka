import Foundation
import Testing

@testable import MontazhkaKit

@Suite
struct ProjectSaveCoordinatorTests {
    @MainActor
    @Test
    func testSchedulePersistsProjectAfterDebounce() async {
        let repository = RepositoryMock()
        let coordinator = ProjectSaveCoordinator(repository: repository)
        let project = Project(name: "debounce")

        coordinator.schedule(project)

        let saved = await waitUntil(timeout: .seconds(3)) { coordinator.status == .saved }
        #expect(saved, "Автосохранение не наступило за отведённый debounce-интервал")
        #expect(repository.savedProjects.map(\.name) == ["debounce"])
    }

    @MainActor
    @Test
    func testSecondScheduleCancelsPendingAndSavesOnlyLatestProject() async {
        let repository = RepositoryMock()
        let coordinator = ProjectSaveCoordinator(repository: repository)

        coordinator.schedule(Project(name: "первый"))
        coordinator.schedule(Project(name: "второй"))

        let saved = await waitUntil(timeout: .seconds(3)) {
            coordinator.status == .saved && repository.savedProjects.count == 1
        }
        #expect(saved, "Отложенное сохранение не выполнилось")
        // Дебаунс должен успеть отменить первую задачу, пока она ещё спит.
        #expect(repository.savedProjects.map(\.name) == ["второй"])
    }

    @MainActor
    @Test
    func testSaveNowWritesImmediatelyWithoutDebounceDelay() async {
        let repository = RepositoryMock()
        let coordinator = ProjectSaveCoordinator(repository: repository)
        let project = Project(name: "немедленно")

        await coordinator.saveNow(project)

        #expect(repository.savedProjects.map(\.name) == ["немедленно"])
        #expect(coordinator.status == .saved)
    }

    @MainActor
    @Test
    func testSaveFailureSetsFailedStatusAndDismissRestoresIdle() async throws {
        let repository = RepositoryMock()
        repository.saveError = StubError.дискНедоступен
        let coordinator = ProjectSaveCoordinator(repository: repository)

        await coordinator.saveNow(Project(name: "падение"))

        guard case .failed(let message) = coordinator.status else {
            Issue.record("Ожидался статус failed, получен \(coordinator.status)")
            return
        }
        #expect(message.message.contains("диск недоступен"))

        coordinator.dismissError()
        #expect(coordinator.status == .idle)
    }

    @MainActor
    @Test
    func testCancelPendingPreventsDeferredSave() async {
        let repository = RepositoryMock()
        let coordinator = ProjectSaveCoordinator(repository: repository)

        coordinator.schedule(Project(name: "отменён"))
        coordinator.cancelPending()
        // Ждём заметно дольше debounce-интервала: если отмена не сработала,
        // отложенное сохранение успело бы записаться.
        try? await Task.sleep(for: .milliseconds(800))

        #expect(repository.savedProjects.isEmpty)
        #expect(coordinator.status == .saving)
    }

    @MainActor
    @Test
    func testSaveBeforeTerminationReportsSuccessAndFailureSynchronously() {
        let okRepository = RepositoryMock()
        let okCoordinator = ProjectSaveCoordinator(repository: okRepository)
        okCoordinator.saveBeforeTermination(Project(name: "успех"))
        #expect(okCoordinator.status == .saved)
        #expect(okRepository.savedProjects.map(\.name) == ["успех"])

        let failingRepository = RepositoryMock()
        failingRepository.terminationError = StubError.дискНедоступен
        let failingCoordinator = ProjectSaveCoordinator(repository: failingRepository)
        failingCoordinator.saveBeforeTermination(Project(name: "провал"))
        guard case .failed(let message) = failingCoordinator.status else {
            Issue.record("Ожидался статус failed при ошибке записи перед завершением")
            return
        }
        #expect(message.message.contains("диск недоступен"))
        // Синхронный путь тоже обязан дойти до репозитория.
        #expect(failingRepository.savedProjects.isEmpty)
    }

    // MARK: - Помощники

    /// Опрос условия без фиксированных sleep'ов: возвращает true, если оно
    /// выполнилось до истечения таймаута.
    @MainActor
    private func waitUntil(
        timeout: Duration,
        _ condition: () -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }
}

private enum StubError: Error, LocalizedError {
    case дискНедоступен

    var errorDescription: String? { "диск недоступен" }
}

/// Записывающий фейк репозитория: сохранённые проекты копируются под замком,
/// ошибки инжектируются по отдельным путям записи.
private final class RepositoryMock: ProjectRepository, @unchecked Sendable {
    private let lock = NSLock()
    private var saved: [Project] = []

    var saveError: Error?
    var terminationError: Error?

    var savedProjects: [Project] {
        lock.lock()
        defer { lock.unlock() }
        return saved
    }

    var directories: ProjectDirectories {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
        return ProjectDirectories(
            projects: root, waveforms: root, enhancedAudio: root,
            musicEQ: root, transcripts: root, models: root, shortsAnalysis: root)
    }

    func save(_ project: Project) async throws {
        if let saveError { throw saveError }
        lock.withLock { saved.append(project) }
    }

    func load(id: UUID) async throws -> Project {
        struct NotFound: Error {}
        throw NotFound()
    }

    func delete(id: UUID) async throws {}

    func listProjects() async throws -> ProjectListing {
        ProjectListing(projects: [], issues: [])
    }

    func saveBeforeTermination(_ project: Project) throws {
        if let terminationError { throw terminationError }
        lock.lock()
        saved.append(project)
        lock.unlock()
    }
}
