import Foundation
import OSLog
import Observation

@MainActor
@Observable
final class ProjectSaveCoordinator {
    private(set) var status: ProjectSaveStatus = .idle

    private let repository: any ProjectRepository
    @ObservationIgnored private var pendingTask: Task<Void, Never>?
    @ObservationIgnored private var generation = Generation()

    init(repository: any ProjectRepository) {
        self.repository = repository
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
        do {
            try await repository.save(project)
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
