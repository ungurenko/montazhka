import Foundation
import Testing

@testable import MontazhkaKit

/// Окно и агент пишут один файл проекта. Сверка версии и запись — одно действие:
/// правка, вставшая между ними, даёт конфликт, а не молчаливую перезапись.
/// Порядок событий задают барьеры, а не удачный тайминг.
@Suite("Project saves check the revision they started from")
struct ProjectRevisionTests {
    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("montazhka-revision-\(UUID().uuidString)", isDirectory: true)
    }

    private func sharedProject(in root: URL) async throws -> Project {
        var project = Project(name: "общий")
        project.clips = [Clip(sourcePath: "/tmp/a.mov", start: 0, end: 10)]
        try await ProjectStore(baseDirectory: root).save(project)
        return project
    }

    @MainActor
    @Test("an agent write landing between the window's check and its write is a conflict, not an overwrite")
    func agentWriteBetweenCheckAndSave() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try await sharedProject(in: root)
        let agentStore = ProjectStore(baseDirectory: root)
        var agentVersion = project
        agentVersion.clips = [Clip(sourcePath: "/tmp/a.mov", start: 0, end: 4)]
        let window = BarrierRepository(ProjectStore(baseDirectory: root))
        let agentWrite = agentVersion
        window.beforeWrite = { try await agentStore.save(agentWrite) }
        let coordinator = ProjectSaveCoordinator(repository: window)
        coordinator.adoptDiskRevision(for: project.id)
        var externalChanges = 0
        coordinator.onExternalChange = { _ in externalChanges += 1 }

        var windowVersion = project
        windowVersion.name = "правка окна"
        await coordinator.saveNow(windowVersion)

        let onDisk = try await agentStore.load(id: project.id)
        #expect(onDisk.clips.map(\.end) == [4], "правка агента на месте")
        #expect(onDisk.name == "общий")
        #expect(externalChanges == 1, "окно узнало о конфликте")
        let copies = try await agentStore.listProjects().projects.filter { $0.id != project.id }
        #expect(copies.count == 1, "версия окна сохранена копией и переживёт перезапуск")
        if let copy = copies.first {
            #expect(try await agentStore.load(id: copy.id).name.hasPrefix("правка окна"))
        }
    }

    @MainActor
    @Test("a write landing right after the window reads the project is noticed, not adopted as seen")
    func writeRightAfterReload() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try await sharedProject(in: root)
        let agentStore = ProjectStore(baseDirectory: root)
        let window = BarrierRepository(ProjectStore(baseDirectory: root))
        let controller = EditorController(
            project: project, store: window, openRouterKeyStore: EmptyOpenRouterKeyStore())
        var second = project
        second.clips = [Clip(sourcePath: "/tmp/a.mov", start: 0, end: 6)]
        try await agentStore.save(second)
        var third = project
        third.clips = [Clip(sourcePath: "/tmp/a.mov", start: 0, end: 3)]
        let thirdWrite = third
        window.afterRead = { try await agentStore.save(thirdWrite) }

        await controller.reloadChangedProject(lostLocalEdit: false)
        for _ in 0..<40 where controller.project.clips.map(\.end) != [3] {
            try await Task.sleep(for: .milliseconds(100))
        }

        #expect(controller.project.clips.map(\.end) == [3], "третья версия подхвачена, а не принята за виденную")
        await controller.shutdown()
        #expect(try await agentStore.load(id: project.id).clips.map(\.end) == [3], "закрытие её не затёрло")
    }

    @MainActor
    @Test("quitting after an agent edit keeps the window's version as a recoverable copy")
    func terminationConflictKeepsCopy() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = try await sharedProject(in: root)
        let store = ProjectStore(baseDirectory: root)
        let coordinator = ProjectSaveCoordinator(repository: store)
        coordinator.adoptDiskRevision(for: project.id)
        var agentVersion = project
        agentVersion.clips = [Clip(sourcePath: "/tmp/a.mov", start: 0, end: 4)]
        try await ProjectStore(baseDirectory: root).save(agentVersion)

        var windowVersion = project
        windowVersion.name = "перед выходом"
        coordinator.saveBeforeTermination(windowVersion)

        #expect(try await store.load(id: project.id).clips.map(\.end) == [4])
        let copies = try await store.listProjects().projects.filter { $0.id != project.id }
        #expect(copies.map(\.name).contains { $0.hasPrefix("перед выходом") })
    }
}

/// Настоящее хранилище, в которое тест вставляет чужую запись в нужный момент:
/// перед записью окна или сразу после его чтения. Каждый барьер срабатывает один раз.
private final class BarrierRepository: ProjectRepository, @unchecked Sendable {
    private let store: ProjectStore
    private let lock = NSLock()
    private var pendingBeforeWrite: (@Sendable () async throws -> Void)?
    private var pendingAfterRead: (@Sendable () async throws -> Void)?

    init(_ store: ProjectStore) { self.store = store }

    var beforeWrite: (@Sendable () async throws -> Void)? {
        get { lock.withLock { pendingBeforeWrite } }
        set { lock.withLock { pendingBeforeWrite = newValue } }
    }

    var afterRead: (@Sendable () async throws -> Void)? {
        get { lock.withLock { pendingAfterRead } }
        set { lock.withLock { pendingAfterRead = newValue } }
    }

    private func take(_ keyPath: ReferenceWritableKeyPath<BarrierRepository, (@Sendable () async throws -> Void)?>)
        -> (@Sendable () async throws -> Void)?
    {
        lock.withLock {
            let barrier = self[keyPath: keyPath]
            self[keyPath: keyPath] = nil
            return barrier
        }
    }

    var directories: ProjectDirectories { store.directories }

    func save(_ project: Project) async throws { try await store.save(project) }

    func save(_ project: Project, expected: ProjectRevision?) async throws -> ProjectRevision {
        if let barrier = take(\.pendingBeforeWrite) { try await barrier() }
        return try await store.save(project, expected: expected)
    }

    func load(id: UUID) async throws -> Project { try await loadWithRevision(id: id).project }

    func loadWithRevision(id: UUID) async throws -> (project: Project, revision: ProjectRevision) {
        let loaded = try await store.loadWithRevision(id: id)
        if let barrier = take(\.pendingAfterRead) { try await barrier() }
        return loaded
    }

    func delete(id: UUID) async throws { try await store.delete(id: id) }
    func listProjects() async throws -> ProjectListing { try await store.listProjects() }

    func saveBeforeTermination(_ project: Project, expected: ProjectRevision?) throws -> ProjectRevision {
        try store.saveBeforeTermination(project, expected: expected)
    }

    func revision(of id: UUID) -> ProjectRevision? { store.revision(of: id) }
}
