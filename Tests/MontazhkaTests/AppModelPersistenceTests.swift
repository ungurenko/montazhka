import Foundation
import XCTest
@testable import Montazhka

final class AppModelPersistenceTests: XCTestCase {
    @MainActor
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

        XCTAssertEqual(app.editor?.project.id, second.id)
        if let editor = app.editor { await editor.shutdown() }
    }

    @MainActor
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
        XCTAssertNotNil(app.editor)
        XCTAssertTrue(app.isProjectOperationInProgress)

        repository.completeNextSave()
        try await waitUntil { app.editor == nil }
        XCTAssertFalse(app.isProjectOperationInProgress)
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
        XCTFail("Условие не выполнилось вовремя")
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

    init() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("montazhka-controlled-\(UUID().uuidString)", isDirectory: true)
        directories = ProjectDirectories(
            projects: root.appendingPathComponent("Projects"),
            waveforms: root.appendingPathComponent("Waveforms"),
            enhancedAudio: root.appendingPathComponent("EnhancedAudio"),
            musicEQ: root.appendingPathComponent("MusicEQ"),
            transcripts: root.appendingPathComponent("Transcripts"),
            models: root.appendingPathComponent("Models")
        )
        for url in [directories.projects, directories.waveforms, directories.enhancedAudio,
                    directories.musicEQ, directories.transcripts, directories.models] {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    var blocksSaves: Bool {
        get { lock.withLock { shouldBlockSaves } }
        set { lock.withLock { shouldBlockSaves = newValue } }
    }

    var pendingLoadCount: Int { lock.withLock { loadWaiters.count } }
    var pendingSaveCount: Int { lock.withLock { saveWaiters.count } }

    func save(_ project: Project) async throws {
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

    func delete(id: UUID) async throws {}
    func listProjects() async throws -> ProjectListing { ProjectListing(projects: [], issues: []) }
    func saveBeforeTermination(_ project: Project) throws {}

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
