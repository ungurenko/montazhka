import Foundation
import Testing

@testable import MontazhkaKit

@Suite
struct AppModelPersistenceTests {
    @MainActor
    @Test
    func testLatestProjectSelectionWinsWhenOlderLoadFinishesLast() async throws {
        let repository = ControlledProjectRepository()
        let app = AppModel(store: repository)
        let first = Project(name: "Первый")
        let second = Project(name: "Второй")

        app.openProject(id: first.id)
        app.openProject(id: second.id)
        try await waitUntil { repository.pendingLoadCount == 2 }

        repository.completeLoad(second)
        try await waitUntil { app.editor?.project.id == second.id }
        repository.completeLoad(first)
        try await Task.sleep(for: .milliseconds(30))

        #expect((app.editor?.project.id) == (second.id))
        if let editor = app.editor { await editor.shutdown() }
    }

    @MainActor
    @Test
    func testClosingKeepsEditorVisibleUntilFinalSaveCompletes() async throws {
        let repository = ControlledProjectRepository()
        repository.blocksSaves = true
        let app = AppModel(store: repository)
        let controller = EditorController(
            project: Project(name: "Сохраняется"),
            store: repository,
            openRouterKeyStore: EmptyOpenRouterKeyStore()
        )
        app.editor = controller

        app.closeProject()
        try await waitUntil { repository.pendingSaveCount == 1 }
        #expect((app.editor) != nil)
        #expect(app.isProjectOperationInProgress)

        repository.completeNextSave()
        try await waitUntil { app.editor == nil }
        #expect(!(app.isProjectOperationInProgress))
    }

    @MainActor
    @Test("a failed final save keeps the project open with its edits; retry then closes it")
    func failedSaveKeepsProjectOpen() async throws {
        let repository = ControlledProjectRepository()
        let app = AppModel(store: repository)
        let controller = EditorController(
            project: Project(name: "Черновик"), store: repository, openRouterKeyStore: EmptyOpenRouterKeyStore())
        app.editor = controller
        controller.renameProject("Правка в памяти")
        repository.saveError = CocoaError(.fileWriteOutOfSpace)

        app.closeProject()
        try await waitUntil { app.closeFailure != nil }

        #expect(app.editor === controller, "редактор остался открытым")
        #expect(controller.project.name == "Правка в памяти", "правка в памяти")
        #expect(app.closeFailure?.what == "На диске не хватает места.")
        #expect(!app.isProjectOperationInProgress)

        repository.saveError = nil
        app.closeProject()
        try await waitUntil { app.editor == nil }
        #expect(app.closeFailure == nil)
        #expect(repository.savedNames.last == "Правка в памяти")
    }

    @MainActor
    @Test("an edit made while the final save is running is saved too before the project closes")
    func editDuringFinalSaveIsSaved() async throws {
        let repository = ControlledProjectRepository()
        repository.blocksSaves = true
        let app = AppModel(store: repository)
        let controller = EditorController(
            project: Project(name: "Первая"), store: repository, openRouterKeyStore: EmptyOpenRouterKeyStore())
        app.editor = controller

        app.closeProject()
        try await waitUntil { repository.pendingSaveCount == 1 }
        controller.renameProject("Правка во время записи")
        repository.completeNextSave()
        try await waitUntil { repository.pendingSaveCount == 1 }
        controller.renameProject("Ещё одна")
        repository.completeNextSave()
        // Закрытие не заканчивается, пока записан не самый свежий вариант (отложенное
        // автосохранение сработало бы только через полсекунды — уже после закрытия).
        try await waitUntil { app.editor == nil || repository.pendingSaveCount == 1 }
        if app.editor != nil { repository.completeNextSave() }
        try await waitUntil { app.editor == nil }

        #expect(repository.savedNames.last == "Ещё одна")
    }

    @MainActor
    @Test("closing without saving is an explicit choice and writes nothing")
    func closeWithoutSaving() async throws {
        let repository = ControlledProjectRepository()
        let app = AppModel(store: repository)
        let controller = EditorController(
            project: Project(name: "Черновик"), store: repository, openRouterKeyStore: EmptyOpenRouterKeyStore())
        app.editor = controller
        repository.saveError = CocoaError(.fileWriteOutOfSpace)
        app.closeProject()
        try await waitUntil { app.closeFailure != nil }
        let writes = repository.savedNames.count

        await app.closeWithoutSaving()

        #expect(app.editor == nil)
        #expect(app.closeFailure == nil)
        #expect(repository.savedNames.count == writes)
    }

    @MainActor
    @Test("quitting waits for the final save and is refused when it fails")
    func quitWaitsForSave() async throws {
        let repository = ControlledProjectRepository()
        let app = AppModel(store: repository)
        app.editor = EditorController(
            project: Project(name: "Выход"), store: repository, openRouterKeyStore: EmptyOpenRouterKeyStore())
        repository.saveError = CocoaError(.fileWriteNoPermission)

        #expect(await app.closeForTermination() == false)
        #expect(app.editor != nil)
        #expect(app.closeFailure != nil)

        repository.saveError = nil
        #expect(await app.closeForTermination() == true)
        #expect(app.editor == nil)
    }

    @MainActor
    private func waitUntil(
        timeoutIterations: Int = 100,
        _ condition: @escaping () -> Bool
    ) async throws {
        for _ in 0..<timeoutIterations {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Условие не выполнилось вовремя")
    }
}

private final class ControlledProjectRepository: ProjectRepository, @unchecked Sendable {
    private struct LoadWaiter {
        let id: UUID
        let continuation: CheckedContinuation<Project, Error>
    }

    let directories: ProjectDirectories
    private let lock = NSLock()
    private var loadWaiters: [LoadWaiter] = []
    private var saveWaiters: [CheckedContinuation<Void, Never>] = []
    private var shouldBlockSaves = false
    private var failure: Error?
    private var saved: [String] = []

    init() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("montazhka-controlled-\(UUID().uuidString)", isDirectory: true)
        directories = ProjectDirectories(
            projects: root.appendingPathComponent("Projects"),
            waveforms: root.appendingPathComponent("Waveforms"),
            enhancedAudio: root.appendingPathComponent("EnhancedAudio"),
            musicEQ: root.appendingPathComponent("MusicEQ"),
            transcripts: root.appendingPathComponent("Transcripts"),
            models: root.appendingPathComponent("Models"),
            shortsAnalysis: root.appendingPathComponent("ShortsAnalysis")
        )
        for url in [
            directories.projects, directories.waveforms, directories.enhancedAudio,
            directories.musicEQ, directories.transcripts, directories.models,
            directories.shortsAnalysis,
        ] {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    var blocksSaves: Bool {
        get { lock.withLock { shouldBlockSaves } }
        set { lock.withLock { shouldBlockSaves = newValue } }
    }

    var saveError: Error? {
        get { lock.withLock { failure } }
        set { lock.withLock { failure = newValue } }
    }

    var savedNames: [String] { lock.withLock { saved } }

    var pendingLoadCount: Int { lock.withLock { loadWaiters.count } }
    var pendingSaveCount: Int { lock.withLock { saveWaiters.count } }

    func save(_ project: Project) async throws {
        if let saveError { throw saveError }
        lock.withLock { saved.append(project.name) }
        guard blocksSaves else { return }
        await withCheckedContinuation { continuation in
            lock.withLock { saveWaiters.append(continuation) }
        }
    }

    func load(id: UUID) async throws -> Project {
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock { loadWaiters.append(LoadWaiter(id: id, continuation: continuation)) }
        }
    }

    func save(_ project: Project, expected: ProjectRevision?) async throws -> ProjectRevision {
        try await save(project)
        return ProjectRevision(digest: UUID().uuidString)
    }

    func loadWithRevision(id: UUID) async throws -> (project: Project, revision: ProjectRevision) {
        (try await load(id: id), ProjectRevision(digest: id.uuidString))
    }

    func delete(id: UUID) async throws {}
    func listProjects() async throws -> ProjectListing { ProjectListing(projects: [], issues: []) }

    func saveBeforeTermination(_ project: Project, expected: ProjectRevision?) throws -> ProjectRevision {
        ProjectRevision(digest: UUID().uuidString)
    }

    func revision(of id: UUID) -> ProjectRevision? { nil }

    func completeLoad(_ project: Project) {
        let continuation: CheckedContinuation<Project, Error>? = lock.withLock {
            guard let index = loadWaiters.firstIndex(where: { $0.id == project.id }) else { return nil }
            return loadWaiters.remove(at: index).continuation
        }
        continuation?.resume(returning: project)
    }

    func completeNextSave() {
        let continuation: CheckedContinuation<Void, Never>? = lock.withLock {
            saveWaiters.isEmpty ? nil : saveWaiters.removeFirst()
        }
        continuation?.resume()
    }
}
